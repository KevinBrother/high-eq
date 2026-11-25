// Synthetic alert receiver for the isolated T34 lab. It never logs request
// bodies; only the delivery count is exposed for health and acceptance checks.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"time"
)

var delivered atomic.Uint64

func sinkHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// Drain within a bound so delivery remains honest without retaining payloads.
	_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 64<<10))
	delivered.Add(1)
	w.WriteHeader(http.StatusAccepted)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]uint64{"alerts": delivered.Load()})
}

func get(url string) (int, []byte, error) {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return resp.StatusCode, body, err
}

func main() {
	url := os.Getenv("SINK_URL")
	if url == "" {
		url = "http://127.0.0.1:8080"
	}
	switch {
	case len(os.Args) == 2 && os.Args[1] == "healthcheck":
		status, _, err := get(url + "/health")
		if err != nil || status != http.StatusOK {
			os.Exit(1)
		}
		return
	case len(os.Args) == 2 && os.Args[1] == "count":
		status, body, err := get(url + "/health")
		if err != nil || status != http.StatusOK {
			os.Exit(1)
		}
		var health map[string]uint64
		if json.Unmarshal(body, &health) != nil {
			os.Exit(1)
		}
		fmt.Println(strconv.FormatUint(health["alerts"], 10))
		return
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/alerts", sinkHandler)
	mux.HandleFunc("/health", healthHandler)
	listen := os.Getenv("LISTEN_ADDR")
	if listen == "" {
		listen = ":8080"
	}
	server := &http.Server{
		Addr:              listen,
		Handler:           mux,
		ReadHeaderTimeout: 3 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       30 * time.Second,
		ErrorLog:          log.New(io.Discard, "", 0),
	}
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		os.Exit(1)
	}
}
