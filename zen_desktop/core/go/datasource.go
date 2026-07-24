package core

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
)

type DataSourceConfig struct {
	Active  string                    `json:"active"`
	Sources map[string]SourceSettings `json:"sources"`
}

type SourceSettings struct {
	Name    string `json:"name"`
	Enabled bool   `json:"enabled"`
	Token   string `json:"token,omitempty"`
}

var (
	configMu      sync.RWMutex
	currentConfig *DataSourceConfig
	configPath    string
	initialized   bool
)

func InitDataSource(path string) {
	configPath = path
	loadConfig()
	initialized = true
}

// CloseDataSource 关闭数据源连接，清理资源
func CloseDataSource() {
	if !initialized {
		return
	}
	configMu.Lock()
	defer configMu.Unlock()
	currentConfig = nil
	configPath = ""
	initialized = false
}

func loadConfig() {
	configMu.Lock()
	defer configMu.Unlock()

	data, err := os.ReadFile(configPath)
	if err != nil {
		currentConfig = &DataSourceConfig{
			Active: "tencent",
			Sources: map[string]SourceSettings{
				"tencent": {Name: "腾讯财经", Enabled: true},
			},
		}
		saveConfig()
		return
	}

	var cfg DataSourceConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		currentConfig = &DataSourceConfig{Active: "tencent"}
		return
	}
	currentConfig = &cfg
}

func saveConfig() {
	if currentConfig == nil || configPath == "" {
		return
	}
	data, _ := json.MarshalIndent(currentConfig, "", "  ")
	os.WriteFile(configPath, data, 0600)
}

func GetDataSourceConfig() *DataSourceConfig {
	configMu.RLock()
	defer configMu.RUnlock()
	return currentConfig
}

func SetActiveDataSource(name string) error {
	configMu.Lock()
	defer configMu.Unlock()

	if currentConfig.Sources != nil {
		if s, ok := currentConfig.Sources[name]; ok && s.Enabled {
			currentConfig.Active = name
			saveConfig()
			return nil
		}
	}
	return fmt.Errorf("data source '%s' not found or disabled", name)
}
