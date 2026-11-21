// admin-account provisions a named operator from a trusted terminal, never over HTTP.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"high-eq/server/internal/adminops"
)

func main() {
	login := flag.String("login", "", "account name (ASCII letters, numbers, dot, dash, underscore)")
	role := flag.String("role", "", "operator or super_admin")
	flag.Parse()
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	raw, e := io.ReadAll(io.LimitReader(os.Stdin, 75))
	if e == nil && len(raw) < 75 {
		db, e := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
		if e == nil {
			defer db.Close()
			pw := strings.TrimSuffix(strings.TrimSuffix(string(raw), "\n"), "\r")
			id, e := adminops.Provision(ctx, db, *login, pw, *role)
			if e == nil {
				fmt.Println("管理员 ID:", id)
				return
			}
		}
	}
	fmt.Fprintln(os.Stderr, "创建失败：请检查数据库、账号名、唯一性、角色及密码长度（12–72 字节）。")
	os.Exit(1)
}
