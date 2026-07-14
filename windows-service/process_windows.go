package main

import (
	"fmt"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

type mihomoProcess struct {
	cmd      *exec.Cmd
	exit     chan error
	logFile  *os.File
	stopOnce sync.Once
}

func validateMihomoConfig(paths appPaths) error {
	if err := validateRegularNonEmpty(paths.MihomoExe, ".exe"); err != nil {
		return err
	}
	if err := validateRegularNonEmpty(paths.Config, ".yaml"); err != nil {
		return err
	}
	for _, geodata := range []string{paths.GeoSite, paths.GeoIP, paths.CountryDB} {
		if err := validateRegularNonEmpty(geodata, ""); err != nil {
			return fmt.Errorf("required geodata is unavailable: %w", err)
		}
	}
	cmd := exec.Command(paths.MihomoExe, "-t", "-d", paths.DataDir, "-f", paths.Config)
	cmd.Dir = paths.DataDir
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("mihomo configuration check failed: %w: %s", err, string(output))
	}
	return nil
}

func startMihomo(paths appPaths) (*mihomoProcess, error) {
	logFile, err := os.OpenFile(paths.MihomoLog, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open mihomo log: %w", err)
	}
	cmd := exec.Command(paths.MihomoExe, "-d", paths.DataDir, "-f", paths.Config)
	cmd.Dir = paths.DataDir
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := cmd.Start(); err != nil {
		logFile.Close()
		return nil, fmt.Errorf("start mihomo: %w", err)
	}
	p := &mihomoProcess{cmd: cmd, exit: make(chan error, 1), logFile: logFile}
	go func() {
		err := cmd.Wait()
		logFile.Close()
		p.exit <- err
	}()
	return p, nil
}

func (p *mihomoProcess) pid() int {
	if p == nil || p.cmd == nil || p.cmd.Process == nil {
		return 0
	}
	return p.cmd.Process.Pid
}

func (p *mihomoProcess) stop() error {
	if p == nil || p.cmd == nil || p.cmd.Process == nil {
		return nil
	}
	var result error
	p.stopOnce.Do(func() {
		// Ask the child to terminate cleanly first. Windows may not support the
		// interrupt signal for a hidden process, so a bounded kill is the fallback.
		_ = p.cmd.Process.Signal(os.Interrupt)
		select {
		case <-p.exit:
			return
		case <-time.After(5 * time.Second):
		}
		if err := p.cmd.Process.Kill(); err != nil {
			result = fmt.Errorf("force stop mihomo: %w", err)
			return
		}
		select {
		case <-p.exit:
		case <-time.After(2 * time.Second):
			result = fmt.Errorf("timed out waiting for mihomo to stop")
		}
	})
	return result
}
