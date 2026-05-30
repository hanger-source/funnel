package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"

	"github.com/getlantern/systray"
)

var instanceLock *os.File

func main() {
	initLogger()
	if err := acquireInstanceLock(); err != nil {
		logError("another Funnel instance is already running: %v", err)
		return
	}
	defer instanceLock.Close()

	logInfo("funnel starting")
	defer func() {
		if r := recover(); r != nil {
			logError("PANIC: %v", r)
		}
	}()
	systray.Run(onReady, onExit)
}

func acquireInstanceLock() error {
	lockPath := filepath.Join(ConfigDir(), "funnel.lock")
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return err
	}
	instanceLock = f
	return nil
}

func onReady() {
	systray.SetTemplateIcon(iconOff, iconOff)
	systray.SetTitle("")
	systray.SetTooltip("Funnel")

	app := NewApp()

	mStatus := systray.AddMenuItem("[OFF] 已断开", "")
	mStatus.Disable()
	systray.AddSeparator()

	mConnect := systray.AddMenuItem("连接", "启动代理")
	mDisconnect := systray.AddMenuItem("断开", "停止代理")
	mDisconnect.Hide()
	systray.AddSeparator()

	mReload := systray.AddMenuItem("重新加载配置", "重新读取 config.json")
	mViewLog := systray.AddMenuItem("查看日志", "打开日志文件")
	systray.AddSeparator()
	mVersion := systray.AddMenuItem("Funnel v"+Version, "")
	mVersion.Disable()
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("退出", "")

	// Auto-connect on startup
	if app.Cfg.HasUpstream() || len(app.Cfg.Nodes) > 0 {
		go func() {
			mStatus.SetTitle("连接中...")
			err := app.Connect()
			if err != nil {
				mStatus.SetTitle("[ERR] " + err.Error())
				logError("auto-connect failed: %v", err)
			} else {
				label := app.connectionLabel()
				mStatus.SetTitle("[ON] " + label)
				systray.SetTemplateIcon(iconOn, iconOn)
				mConnect.Hide()
				mDisconnect.Show()
				showNotification("已连接: " + label)
			}
		}()
	} else {
		mStatus.SetTitle("[ERR] 无代理配置，请配置 ~/.funnel/config.json")
	}

	go func() {
		for {
			select {
			case <-mConnect.ClickedCh:
				if !app.Cfg.HasUpstream() && len(app.Cfg.Nodes) == 0 {
					mStatus.SetTitle("[ERR] 无代理配置，请配置 config.json")
					continue
				}
				mStatus.SetTitle("连接中...")
				err := app.Connect()
				if err != nil {
					mStatus.SetTitle("[ERR] " + err.Error())
					logError("connect failed: %v", err)
					continue
				}
				label := app.connectionLabel()
				mStatus.SetTitle("[ON] " + label)
				systray.SetTemplateIcon(iconOn, iconOn)
				mConnect.Hide()
				mDisconnect.Show()
				showNotification("已连接: " + label)

			case <-mDisconnect.ClickedCh:
				app.Disconnect()
				mStatus.SetTitle("[OFF] 已断开")
				systray.SetTemplateIcon(iconOff, iconOff)
				mDisconnect.Hide()
				mConnect.Show()
				showNotification("Funnel 已断开")

			case <-mReload.ClickedCh:
				cfg, err := LoadConfig()
				if err != nil {
					mStatus.SetTitle("[ERR] 配置加载失败: " + err.Error())
					logError("reload config failed: %v", err)
				} else {
					app.Cfg = cfg
					logInfo("config reloaded: %d nodes", len(cfg.Nodes))
					if app.Connected {
						app.Disconnect()
						if err := app.Connect(); err != nil {
							mStatus.SetTitle("[ERR] " + err.Error())
						} else {
							label := app.connectionLabel()
							mStatus.SetTitle("[ON] " + label)
						}
					}
					showNotification("配置已重新加载")
				}

			case <-mViewLog.ClickedCh:
				app.OpenLog()

			case <-mQuit.ClickedCh:
				app.Disconnect()
				systray.Quit()
				os.Exit(0)
			}
		}
	}()
}

func onExit() {}

func showNotification(msg string) {
	cmd := fmt.Sprintf(`display notification "%s" with title "Funnel"`, msg)
	runOsascript(cmd)
}
