// Command templatepatch renders an ApplicationSet templatePatch the way the
// Argo CD ApplicationSet controller does for a goTemplate ApplicationSet:
// text/template with sprig's generic functions minus env, expandenv and
// getHostByName (argo-cd v3.1.8 applicationset/utils/utils.go:31-43), and
// the ApplicationSet's goTemplateOptions. It reads JSON
// {"templatePatch": string, "options": [string], "params": object} on stdin
// and prints the rendered patch, or the template error on stderr with exit 1.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"text/template"

	"github.com/Masterminds/sprig/v3"
)

type request struct {
	TemplatePatch string         `json:"templatePatch"`
	Options       []string       `json:"options"`
	Params        map[string]any `json:"params"`
}

func main() {
	var req request
	if err := json.NewDecoder(os.Stdin).Decode(&req); err != nil {
		fmt.Fprintln(os.Stderr, "decode:", err)
		os.Exit(2)
	}
	funcs := sprig.GenericFuncMap()
	delete(funcs, "env")
	delete(funcs, "expandenv")
	delete(funcs, "getHostByName")
	tmpl, err := template.New("").Funcs(funcs).Option(req.Options...).Parse(req.TemplatePatch)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var out bytes.Buffer
	if err := tmpl.Execute(&out, req.Params); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Stdout.Write(out.Bytes())
}
