// Package profile derives communication hints from attributable observations, not diagnoses.
package profile

import (
	"fmt"
	"slices"
	"strings"

	"github.com/google/uuid"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
)

type axis struct {
	prompt  string
	options []string
}

// Options double as the output allowlist. Neither model prose nor chat excerpts are rendered.
var axes = [...]axis{
	{"遇到新办法时，对方更接近哪一种？", []string{"愿意试试新办法", "喜欢先用熟悉的方法"}},
	{"一起安排行程时呢？", []string{"喜欢事先说好安排", "愿意边走边商量"}},
	{"聊新话题时呢？", []string{"更愿意把想法说出来", "喜欢先听听再说"}},
	{"交换意见时呢？", []string{"会先听听别人的需要", "愿意直接说明自己的需要"}},
	{"计划临时改变时呢？", []string{"想先确认接下来的安排", "愿意停一停再决定"}},
	{"遇到分歧时呢？", []string{"愿意一起找兼顾双方的办法", "想先缓一缓再谈分歧", "愿意各让一步", "更想说明自己的立场"}},
	{"若为伴侣，联系减少时呢？其他关系可答还不确定。", []string{"在亲密相处时需要一些独处空间", "在联系减少时想得到回应"}},
}

type Question struct {
	ID     uuid.UUID `json:"id"`
	Prompt string    `json:"prompt"`
}

func Questions() []Question {
	var qs []Question
	for i, a := range axes {
		qs = append(qs, Question{uuid.NewSHA1(uuid.NameSpaceURL, []byte(fmt.Sprintf("heq:contact-question:v1:%d", i))), a.prompt + "可填：" + strings.Join(a.options, " / ") + " / 还不确定"})
	}
	return qs
}

type vote struct {
	Axis   int
	Option int
}
type dossier struct {
	Nickname          string
	Scene             app.ContactScene
	Answers, Material [len(axes)]int
}

func scene(s string) bool {
	return slices.Contains([]string{"work", "partner", "family", "friends", "social"}, s)
}
func text(s string, max int) bool { return strings.TrimSpace(s) != "" && len([]rune(s)) <= max }
func (d *dossier) edit(name, sc string, obs *string) error {
	if !text(name, 80) || !scene(sc) || (obs != nil && !text(*obs, 2000)) {
		return accounts.ErrInvalid
	}
	d.Nickname = strings.TrimSpace(name)
	d.Scene = app.ContactScene(sc)
	if obs != nil {
		if v, ok := observed(*obs); ok {
			d.Answers[v.Axis] = v.Option
		}
	}
	if sc != "partner" {
		d.Answers[6] = 0
		d.Material[6] = 0
	}
	return nil
}

// Natural-language answers have deliberately narrow, exact aliases: a negation,
// quotation or ambiguous description must not be mistaken for a trait.
var aliases = map[string]string{
	"愿意尝试": "愿意试试新办法", "先做计划": "喜欢事先说好安排", "先听再说": "喜欢先听听再说",
	"先问对方的需要": "会先听听别人的需要", "先确认安排": "想先确认接下来的安排", "一起商量": "愿意一起找兼顾双方的办法",
	"稍后再谈": "想先缓一缓再谈分歧", "各让一步": "愿意各让一步", "想自己待一会儿": "在亲密相处时需要一些独处空间", "希望收到回复": "在联系减少时想得到回应",
}

func observed(s string) (vote, bool) {
	s = strings.TrimSpace(s)
	if v, ok := aliases[s]; ok {
		s = v
	}
	for i, a := range axes {
		if n := slices.Index(a.options, strings.TrimSpace(strings.TrimPrefix(s, "可能的倾向："))); n >= 0 {
			return vote{i, n + 1}, true
		}
	}
	return vote{}, false
}
func initial(in app.CreateContactInput) (d dossier, e error) {
	if e = d.edit(in.Nickname, string(in.Scene), in.InitialContext); e != nil {
		return
	}
	if in.Answers == nil {
		return
	}
	seen := map[uuid.UUID]bool{}
	qs := Questions()
	for _, a := range *in.Answers {
		i := slices.IndexFunc(qs, func(q Question) bool { return q.ID == a.QuestionId })
		if i < 0 || seen[a.QuestionId] || !text(a.Answer, 1000) {
			return d, accounts.ErrInvalid
		}
		seen[a.QuestionId] = true
		if v, ok := observed(a.Answer); ok && v.Axis == i && (i != 6 || d.Scene == "partner") {
			d.Answers[i] = v.Option
		}
	}
	return
}

type trait = struct {
	Confidence float32 `json:"confidence"`
	Label      string  `json:"label"`
}

const unknown = "线索还不够，可以再观察几次"

func (d dossier) render(votes []vote) app.Profile {
	p := app.Profile{Summary: unknown, BigFive: []trait{}}
	for i, a := range axes {
		if i == 6 && d.Scene != "partner" {
			continue
		}
		counts := make([]int, len(a.options)+1)
		for _, v := range append([]vote{{i, d.Answers[i]}, {i, d.Material[i]}}, votes...) {
			if v.Axis == i && v.Option > 0 && v.Option < len(counts) {
				counts[v.Option]++
			}
		}
		best, n := 0, 0
		for j, v := range counts {
			if v > n {
				best, n = j, v
			}
		}
		t := trait{Label: unknown}
		against := 0
		for j, v := range counts {
			if j != best {
				against += v
			}
		}
		if n > against {
			t.Label = a.options[best-1]
			t.Confidence = float32(n) / float32(n+against+2)
			if p.Summary == unknown || i == 5 {
				p.Summary = "对方可能" + t.Label
			}
		}
		switch {
		case i < 5:
			p.BigFive = append(p.BigFive, t)
		case i == 5:
			p.ConflictStyle = t
		case d.Scene == "partner":
			p.Attachment = &t
		}
	}
	return p
}
