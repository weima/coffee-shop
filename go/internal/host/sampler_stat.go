package host

// The parser is separate from the reader so it can be tested anywhere, including the
// macOS machine this is developed on: the Linux build only adds the file reads.

import (
	"strconv"
	"strings"
)

// procStatFields reads the fields the sampler needs from one `/proc/<pid>/stat` line:
// the parent, user and system ticks, and the resident page count. The command name is
// wrapped in parentheses and may itself contain spaces or parentheses, so counting starts
// after the last ')'.
func procStatFields(text string) (ppid, utime, stime, rssPages uint64, ok bool) {
	closing := strings.LastIndexByte(text, ')')
	if closing < 0 {
		return 0, 0, 0, 0, false
	}
	fields := strings.Fields(text[closing+1:])
	// fields[0] is the state; ppid is fields[1], utime fields[11], stime fields[12],
	// and rss fields[21].
	if len(fields) < 22 {
		return 0, 0, 0, 0, false
	}
	var err error
	if ppid, err = strconv.ParseUint(fields[1], 10, 64); err != nil {
		return 0, 0, 0, 0, false
	}
	if utime, err = strconv.ParseUint(fields[11], 10, 64); err != nil {
		return 0, 0, 0, 0, false
	}
	if stime, err = strconv.ParseUint(fields[12], 10, 64); err != nil {
		return 0, 0, 0, 0, false
	}
	if rssPages, err = strconv.ParseUint(fields[21], 10, 64); err != nil {
		return 0, 0, 0, 0, false
	}
	return ppid, utime, stime, rssPages, true
}
