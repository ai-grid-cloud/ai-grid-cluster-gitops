// appsetgen renders an ApplicationSet's template (and templatePatch) for given
// generator params, templating every string the way Argo CD's goTemplate does.
// stdin: {"spec": <ApplicationSet spec>, "params": [<param map>...]}
// stdout: [<Application spec>...]
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"text/template"

	"github.com/Masterminds/sprig/v3"
	"sigs.k8s.io/yaml"
)

func funcs() template.FuncMap {
	f := sprig.TxtFuncMap()
	delete(f, "env")
	delete(f, "expandenv")
	delete(f, "getHostByName")
	f["toYaml"] = func(v any) string { b, _ := yaml.Marshal(v); return string(b) }
	f["fromYaml"] = func(s string) map[string]any { m := map[string]any{}; _ = yaml.Unmarshal([]byte(s), &m); return m }
	return f
}

func render(s string, p map[string]any) string {
	t := template.Must(template.New("").Option("missingkey=error").Funcs(funcs()).Parse(s))
	var b bytes.Buffer
	if err := t.Execute(&b, p); err != nil {
		fmt.Fprintln(os.Stderr, "template error:", err)
		os.Exit(2)
	}
	return b.String()
}

func walk(v any, p map[string]any) any {
	switch x := v.(type) {
	case string:
		return render(x, p)
	case map[string]any:
		out := map[string]any{}
		for k, val := range x {
			out[render(k, p)] = walk(val, p)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, val := range x {
			out[i] = walk(val, p)
		}
		return out
	}
	return v
}

func merge(dst, src map[string]any) {
	for k, v := range src {
		if sm, ok := v.(map[string]any); ok {
			if dm, ok := dst[k].(map[string]any); ok {
				merge(dm, sm)
				continue
			}
		}
		dst[k] = v
	}
}

func main() {
	var in struct {
		Spec   map[string]any   `json:"spec"`
		Params []map[string]any `json:"params"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	tmpl := in.Spec["template"]
	patch, _ := in.Spec["templatePatch"].(string)
	var out []any
	for _, p := range in.Params {
		app := walk(tmpl, p).(map[string]any)
		if patch != "" {
			m := map[string]any{}
			if err := yaml.Unmarshal([]byte(render(patch, p)), &m); err != nil {
				fmt.Fprintln(os.Stderr, "templatePatch is not YAML:", err)
				os.Exit(2)
			}
			merge(app, m)
		}
		out = append(out, app)
	}
	json.NewEncoder(os.Stdout).Encode(out)
}
