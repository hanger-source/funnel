package main

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Security -framework Foundation
#include <Security/Security.h>
#include <stdlib.h>

int installHelper(const char* script) {
    AuthorizationRef auth;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
        kAuthorizationFlagDefaults, &auth);
    if (status != errAuthorizationSuccess) return 1;

    AuthorizationItem items = {kAuthorizationRightExecute, 0, NULL, 0};
    AuthorizationRights rights = {1, &items};
    AuthorizationFlags flags = kAuthorizationFlagDefaults |
        kAuthorizationFlagInteractionAllowed |
        kAuthorizationFlagPreAuthorize |
        kAuthorizationFlagExtendRights;

    status = AuthorizationCopyRights(auth, &rights, NULL, flags, NULL);
    if (status != errAuthorizationSuccess) {
        AuthorizationFree(auth, kAuthorizationFlagDefaults);
        return 2;
    }

    char* args[] = {"-c", (char*)script, NULL};
    FILE* pipe = NULL;

    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    status = AuthorizationExecuteWithPrivileges(auth, "/bin/sh", kAuthorizationFlagDefaults, args, &pipe);
    #pragma clang diagnostic pop

    if (pipe) {
        char buf[256];
        while (fgets(buf, sizeof(buf), pipe)) {}
        fclose(pipe);
    }

    AuthorizationFree(auth, kAuthorizationFlagDefaults);
    return (status == errAuthorizationSuccess) ? 0 : 3;
}
*/
import "C"

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	helperInstallPath = "/usr/local/bin/funnel-helper"
	plistInstallPath  = "/Library/LaunchDaemons/com.funnel.helper.plist"
)

func fileHash(path string) []byte {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	h := sha256.New()
	io.Copy(h, f)
	return h.Sum(nil)
}

func isHelperInstalled() bool {
	logInfo("checking helper installation...")
	if _, err := os.Stat(helperInstallPath); err != nil {
		logInfo("helper binary not found at %s", helperInstallPath)
		return false
	}
	logInfo("helper binary exists at %s", helperInstallPath)
	out, _ := exec.Command("launchctl", "print", "system/com.funnel.helper").CombinedOutput()
	if strings.Contains(string(out), "Could not find") {
		logInfo("helper daemon not loaded in launchd")
		return false
	}
	logInfo("helper daemon is loaded")
	// Check if binary needs update
	bundled := findBundledHelper()
	if bundled == "" {
		logInfo("no bundled helper found, assuming installed is OK")
		return true
	}
	if !bytes.Equal(fileHash(helperInstallPath), fileHash(bundled)) {
		logInfo("helper binary outdated, needs update")
		return false
	}
	logInfo("helper is up-to-date")
	return true
}

func findBundledHelper() string {
	candidates := []string{
		filepath.Join(getAppResourcesDir(), "funnel-helper"),
	}
	exePath, _ := os.Executable()
	if exePath != "" {
		candidates = append(candidates, filepath.Join(filepath.Dir(exePath), "..", "Resources", "funnel-helper"))
	}
	home, _ := os.UserHomeDir()
	candidates = append(candidates, filepath.Join(home, "projects", "funnel", "helper", "funnel-helper"))
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			logInfo("found bundled helper at %s", c)
			return c
		}
	}
	return ""
}

func installHelperIfNeeded() error {
	if isHelperInstalled() {
		logInfo("helper already installed and up-to-date")
		return nil
	}

	logInfo("installing privileged helper...")

	helperSrc := findBundledHelper()
	if helperSrc == "" {
		return fmt.Errorf("helper binary not found (build it first: cd helper && go build -o funnel-helper .)")
	}

	// Find plist
	plistSrc := filepath.Join(filepath.Dir(helperSrc), "com.funnel.helper.plist")
	if _, err := os.Stat(plistSrc); err != nil {
		return fmt.Errorf("helper plist not found at %s", plistSrc)
	}

	logInfo("helper source: %s", helperSrc)
	logInfo("plist source: %s", plistSrc)

	script := fmt.Sprintf(
		`cp "%s" "%s" && chmod 755 "%s" && chown root:wheel "%s" && `+
			`cp "%s" "%s" && chmod 644 "%s" && chown root:wheel "%s" && `+
			`launchctl bootout system/%s 2>/dev/null; sleep 1; `+
			`launchctl bootstrap system "%s" 2>/dev/null || launchctl load -w "%s"`,
		helperSrc, helperInstallPath, helperInstallPath, helperInstallPath,
		plistSrc, plistInstallPath, plistInstallPath, plistInstallPath,
		"com.funnel.helper",
		plistInstallPath, plistInstallPath,
	)

	logInfo("requesting authorization to install helper...")
	result := C.installHelper(C.CString(script))
	if result != 0 {
		return fmt.Errorf("authorization failed (code %d)", result)
	}

	// Wait until the helper is actually connectable. The socket file appears
	// before the helper fixes its group/mode, so os.Stat alone can race into
	// "connect: permission denied" from the app.
	for i := 0; i < 50; i++ {
		if isHelperReachable() {
			logInfo("helper installed successfully, socket ready")
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}

	return fmt.Errorf("helper failed to start: socket not reachable after 10s")
}

func getAppResourcesDir() string {
	exePath, _ := os.Executable()
	return filepath.Join(filepath.Dir(exePath), "..", "Resources")
}

func isHelperReachable() bool {
	resp, err := sendHelperCommand(HelperRequest{Action: "status"})
	return err == nil && resp != nil && resp.OK
}
