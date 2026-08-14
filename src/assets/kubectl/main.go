/*
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
*/

package main

import (
	"os"

	"k8s.io/component-base/cli"
	"k8s.io/kubectl/pkg/cmd"

	// Load the same client authentication plugins as the official kubectl entrypoint.
	_ "k8s.io/client-go/plugin/pkg/client/auth"
)

func main() {
	os.Exit(cli.Run(cmd.NewDefaultKubectlCommand()))
}
