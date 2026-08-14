package main

import (
	"sort"
	"time"
)

const dayFormat = "2006-01-02"

func emptyCalendar() Calendar {
	return Calendar{Counts: []int{}, Levels: []int{}, MonthStarts: []int{}}
}

// calendarWindow returns the first and last day of the trailing-year grid.
// The start is pulled back to the Sunday on or before (today - 364) so every
// week column is full at the front; only the current week is ever partial.
func calendarWindow(today time.Time) (time.Time, time.Time) {
	today = time.Date(today.Year(), today.Month(), today.Day(), 0, 0, 0, 0, time.UTC)
	start := today.AddDate(0, 0, -364)
	start = start.AddDate(0, 0, -int(start.Weekday()))
	return start, today
}

// buildCalendar turns a "YYYY-MM-DD" -> count map into the dense grid the
// panel draws. Days outside the window are ignored; missing days are zero.
func buildCalendar(counts map[string]int, today time.Time, reportedTotal int) Calendar {
	start, end := calendarWindow(today)
	days := int(end.Sub(start).Hours()/24) + 1
	if days <= 0 {
		return emptyCalendar()
	}

	cal := Calendar{
		Supported:   true,
		Start:       start.Format(dayFormat),
		End:         end.Format(dayFormat),
		Counts:      make([]int, days),
		Levels:      make([]int, days),
		Weeks:       (days + 6) / 7,
		MonthStarts: make([]int, (days+6)/7),
	}

	sum := 0
	for i := 0; i < days; i++ {
		day := start.AddDate(0, 0, i)
		n := counts[day.Format(dayFormat)]
		if n < 0 {
			n = 0
		}
		cal.Counts[i] = n
		sum += n
		if n > cal.Max {
			cal.Max = n
		}
	}
	labelMonths(&cal, start, days)

	cal.Total = sum
	if reportedTotal > 0 {
		cal.Total = reportedTotal
	}
	cal.Today = cal.Counts[days-1]
	cal.Current = currentStreak(cal.Counts)
	cal.Longest = longestStreak(cal.Counts)
	assignLevels(&cal)
	return cal
}

// labelMonths marks each week column with the month that starts inside it, so
// the axis reads Sep Oct Nov ... exactly like the provider's own graph.
func labelMonths(cal *Calendar, start time.Time, days int) {
	for i := range cal.MonthStarts {
		cal.MonthStarts[i] = 0
	}
	lastMonth := 0
	for week := 0; week < cal.Weeks; week++ {
		idx := week * 7
		if idx >= days {
			break
		}
		day := start.AddDate(0, 0, idx)
		month := int(day.Month())
		// The column belongs to the month occupying most of it; a column
		// that opens after the 25th is really the next month's first column.
		if day.Day() > 25 {
			month = int(day.AddDate(0, 0, 7).Month())
		}
		if month != lastMonth {
			cal.MonthStarts[week] = month
			lastMonth = month
		}
	}
}

// currentStreak counts back from today. A quiet today does not break the run
// yet — the day is not over — so the walk starts at yesterday in that case,
// which is how both providers present it.
func currentStreak(counts []int) int {
	n := len(counts)
	if n == 0 {
		return 0
	}
	i := n - 1
	if counts[i] == 0 {
		i--
	}
	streak := 0
	for ; i >= 0 && counts[i] > 0; i-- {
		streak++
	}
	return streak
}

func longestStreak(counts []int) int {
	best, run := 0, 0
	for _, n := range counts {
		if n > 0 {
			run++
			if run > best {
				best = run
			}
		} else {
			run = 0
		}
	}
	return best
}

// assignLevels buckets every day into 0-4 by quartile over the non-zero days,
// so a light week and a heavy week are both readable instead of one washing
// the other out.
func assignLevels(cal *Calendar) {
	nonzero := make([]int, 0, len(cal.Counts))
	for _, n := range cal.Counts {
		if n > 0 {
			nonzero = append(nonzero, n)
		}
	}
	if len(nonzero) == 0 {
		return
	}
	sort.Ints(nonzero)
	q := func(f float64) int {
		idx := int(f * float64(len(nonzero)-1))
		return nonzero[idx]
	}
	q1, q2, q3 := q(0.25), q(0.50), q(0.80)
	for i, n := range cal.Counts {
		switch {
		case n <= 0:
			cal.Levels[i] = 0
		case n <= q1:
			cal.Levels[i] = 1
		case n <= q2:
			cal.Levels[i] = 2
		case n <= q3:
			cal.Levels[i] = 3
		default:
			cal.Levels[i] = 4
		}
	}
}
