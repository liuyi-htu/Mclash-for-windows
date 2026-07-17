package main

import (
	"errors"
	"fmt"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc/mgr"
)

type autoStartResult struct {
	Installed bool `json:"installed"`
	Enabled   bool `json:"enabled"`
}

func queryServiceAutoStart() autoStartResult {
	manager, err := mgr.Connect()
	if err != nil {
		return autoStartResult{}
	}
	defer manager.Disconnect()
	service, err := manager.OpenService(serviceName)
	if err != nil {
		return autoStartResult{}
	}
	defer service.Close()
	config, err := service.Config()
	if err != nil {
		return autoStartResult{Installed: true}
	}
	return autoStartResult{
		Installed: true,
		Enabled:   config.StartType == mgr.StartAutomatic,
	}
}

func setServiceAutoStart(enabled bool) error {
	manager, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer manager.Disconnect()
	service, err := manager.OpenService(serviceName)
	if err != nil {
		if errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
			return fmt.Errorf("service %s is not installed", serviceName)
		}
		return err
	}
	defer service.Close()
	config, err := service.Config()
	if err != nil {
		return err
	}
	config.DelayedAutoStart = false
	if enabled {
		config.StartType = mgr.StartAutomatic
	} else {
		config.StartType = mgr.StartManual
	}
	if err := service.UpdateConfig(config); err != nil {
		return fmt.Errorf("update service startup type: %w", err)
	}
	return nil
}
