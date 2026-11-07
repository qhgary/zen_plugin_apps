//go:build windows

package main

import _ "embed"

//go:embed zen_auth_helper.exe
var embeddedHelper []byte
