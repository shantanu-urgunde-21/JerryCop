package router

import (
	configparser "JerryCop/internal/configParser"
	"strings"
)

// MatchPrefix checks if the request path matches the given prefix
func MatchPrefix(reqPath, prefix string) bool {
	if prefix == "" || prefix == "/" {
		return true
	}
	prefix = strings.TrimSuffix(prefix, "/")
	return reqPath == prefix || strings.HasPrefix(reqPath, prefix+"/")
}

// FindMatchingServer finds the Routing with the longest matching prefix across all servers.
func FindMatchingServer(reqPath string, servers []configparser.ServerConfig) (*configparser.Routing, bool) {
	var bestMatch *configparser.Routing
	longest := -1

	for i := range servers {
		for j := range servers[i].ServerRouting {
			prefix := servers[i].ServerRouting[j].Prefix
			if MatchPrefix(reqPath, prefix) && len(prefix) > longest {
				longest = len(prefix)
				bestMatch = &servers[i].ServerRouting[j]
			}
		}
	}

	return bestMatch, bestMatch != nil
}

// BuildTargetURL joins the upstream base server URL with the request path
// and preserves the original query parameters.
func BuildTargetURL(upstreamBase, reqPath, rawQuery string) (string, error) {
	base := strings.TrimRight(upstreamBase, "/")
	p := reqPath
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}

	totalLen := len(base) + len(p)
	if rawQuery != "" {
		totalLen += 1 + len(rawQuery)
	}

	var b strings.Builder
	b.Grow(totalLen)
	b.WriteString(base)
	b.WriteString(p)
	if rawQuery != "" {
		b.WriteByte('?')
		b.WriteString(rawQuery)
	}

	return b.String(), nil
}
