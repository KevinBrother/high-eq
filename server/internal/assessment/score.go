package assessment

import (
	"errors"
	"math"
)

var ErrInvalid = errors.New("invalid assessment input")

type Dimension struct {
	Mean    float64 `json:"mean"`
	Percent float64 `json:"percent"`
	Display int     `json:"display"`
	Level   string  `json:"level"`
}

type Scores struct {
	Dimensions map[string]Dimension `json:"dimensions"`
	Total      Dimension            `json:"total"`
}

func dimension(mean, p float64) Dimension {
	level := "L5"
	switch {
	case p < 40:
		level = "L1"
	case p < 60:
		level = "L2"
	case p < 75:
		level = "L3"
	case p < 90:
		level = "L4"
	}
	return Dimension{mean, p, int(math.Round(p)), level}
}

// Equal-size dimensions: the total is the mean of the four original means,
// never the mean of their display percentages. Keep integer sums to the last division.
func fromSum(sum, n int) Dimension {
	return dimension(float64(sum)/float64(n), float64((sum-n)*100)/float64(6*n))
}

func (b *Instrument) Score(version string, answers []int) (Scores, error) {
	if version != b.Version || len(answers) != len(b.Items) {
		return Scores{}, ErrInvalid
	}
	out := Scores{Dimensions: make(map[string]Dimension, 4)}
	total := 0
	for dim, g := range b.Dimensions {
		sum := 0
		for _, id := range g.Items {
			v := answers[id-1]
			if v < b.Scale.Min || v > b.Scale.Max {
				return Scores{}, ErrInvalid
			}
			sum += v
		}
		total += sum
		out.Dimensions[dim] = fromSum(sum, len(g.Items))
	}
	out.Total = fromSum(total, len(answers))
	return out, nil
}
