// Package training owns practice history, role play and score settlement.
package training

import (
	"errors"

	"github.com/google/uuid"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
)

type lesson struct {
	app.Level
	scenario string
}

func level(id, title, scene string, d int, target, scenario string) lesson {
	l := app.Level{Id: uuid.MustParse("19000000-0000-4000-8000-0000000000" + id), Title: title, Scene: app.LevelScene(scene), Difficulty: d, Mode: "full_session"}
	if target != "" {
		l.Mode = "single_skill"
		l.TargetItem = &target
	}
	return lesson{l, scenario}
}

var catalog = []lesson{
	level("01", "只说刚才发生的事", "work", 1, "observation", "你是刚打断同事发言的主管，认为会议时间有限。"),
	level("02", "表达失约后的感受", "partner", 1, "feeling", "你是临时取消约会的伴侣，起初以为对方并不介意。"),
	level("03", "说清探访背后的需要", "family", 2, "need", "你是想每周探访的父母之一，担心孩子在疏远自己。"),
	level("04", "把请求说具体", "friends", 1, "request", "你是合租的朋友，经常忘记倒垃圾，愿意讨论分工。"),
	level("05", "拒绝临时加班", "work", 3, "", "你是急于交付的经理，今天需要有人顶班，也可以协商优先级。"),
	level("06", "为迟到道歉", "partner", 2, "", "你是在雨中等了半小时的伴侣，希望被认真对待。"),
	level("07", "回应父母的担心", "family", 2, "", "你是担心孩子转行的家长，想听到具体打算。"),
	level("08", "陪朋友面对落选", "friends", 2, "", "你是面试落选的朋友，现在更想被听见，而非立刻得到建议。"),
	level("09", "协商夜间音量", "social", 3, "", "你是练琴的邻居，下班较晚但愿意听对方解释影响。"),
	level("10", "协作时提出期限", "work", 2, "request", "你是同时接了多项工作的同事，需要对方说明要什么、何时需要。"),
}

func validScene(v string) bool {
	switch v {
	case "work", "partner", "family", "friends", "social":
		return true
	}
	return false
}

func validFocus(v string) bool {
	switch v {
	case "observation", "feeling", "need", "request":
		return true
	}
	return false
}

// PlanLevelIDs resolves the canonical single-skill and full-session levels used
// by T26. Prefer the requested scene, then fall back across scenes so a sparse
// catalog never causes T26 to invent an ID.
func PlanLevelIDs(focus, scene string) (single, full uuid.UUID, err error) {
	if !validFocus(focus) || !validScene(scene) {
		return uuid.Nil, uuid.Nil, accounts.ErrInvalid
	}
	return planLevelIDs(catalog, focus, scene)
}

func planLevelIDs(lessons []lesson, focus, scene string) (single, full uuid.UUID, err error) {
	for _, l := range lessons {
		if string(l.Scene) == scene && l.Mode == "single_skill" && l.TargetItem != nil && *l.TargetItem == focus {
			single = l.Id
			break
		}
	}
	if single == uuid.Nil {
		for _, l := range lessons {
			if l.Mode == "single_skill" && l.TargetItem != nil && *l.TargetItem == focus {
				single = l.Id
				break
			}
		}
	}
	for _, l := range lessons {
		if string(l.Scene) == scene && l.Mode == "full_session" {
			full = l.Id
			break
		}
	}
	if full == uuid.Nil {
		for _, l := range lessons {
			if l.Mode == "full_session" {
				full = l.Id
				break
			}
		}
	}
	if single == uuid.Nil || full == uuid.Nil || single == full {
		return uuid.Nil, uuid.Nil, errors.New("training catalog has no usable plan levels")
	}
	return single, full, nil
}

func limit(v *int) (int, error) {
	if v == nil {
		return 20, nil
	}
	if *v < 1 || *v > 100 {
		return 0, accounts.ErrInvalid
	}
	return *v, nil
}
func Levels(p app.ListLevelsParams) (app.ListLevelsResult, error) {
	out := app.ListLevelsResult{Items: []app.Level{}}
	n, e := limit(p.Limit)
	if e != nil || p.Scene != nil && !validScene(string(*p.Scene)) || p.Difficulty != nil && (*p.Difficulty < 1 || *p.Difficulty > 3) {
		return out, accounts.ErrInvalid
	}
	found := p.Cursor == nil
	for _, l := range catalog {
		if p.Scene != nil && string(l.Scene) != string(*p.Scene) || p.Difficulty != nil && l.Difficulty != *p.Difficulty {
			continue
		}
		if !found {
			found = l.Id.String() == *p.Cursor
			continue
		}
		if len(out.Items) == n {
			v := out.Items[n-1].Id.String()
			out.NextCursor = &v
			break
		}
		out.Items = append(out.Items, l.Level)
	}
	if !found {
		return out, accounts.ErrInvalid
	}
	return out, nil
}
func fits(turns, used, extra int) bool { return turns < 30 && extra >= 0 && extra <= 30000-used }
