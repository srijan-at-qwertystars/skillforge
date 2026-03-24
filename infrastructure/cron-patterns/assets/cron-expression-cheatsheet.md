# Cron Expression Cheatsheet

Quick visual reference for cron scheduling syntax.

---

## Field Layout

```
┌───────────── minute       (0-59)
│ ┌─────────── hour         (0-23)
│ │ ┌───────── day of month (1-31)
│ │ │ ┌─────── month        (1-12 or JAN-DEC)
│ │ │ │ ┌───── day of week  (0-7 or SUN-SAT; 0 and 7 = Sunday)
│ │ │ │ │
* * * * *  command
```

---

## Special Characters

| Char | Meaning | Example | Reads as |
|------|---------|---------|----------|
| `*` | Every value | `* * * * *` | Every minute |
| `,` | List | `1,15,30 * * * *` | At minute 1, 15, and 30 |
| `-` | Range | `0 9-17 * * *` | Every hour from 9 to 17 |
| `/` | Step | `*/5 * * * *` | Every 5 minutes |
| `/` | Offset step | `3/15 * * * *` | At 3, 18, 33, 48 |

### Extended (Quartz/Spring/AWS only)

| Char | Meaning | Example | Reads as |
|------|---------|---------|----------|
| `?` | No specific value | `0 0 ? * MON` | (use when other field is set) |
| `L` | Last | `0 0 L * *` | Last day of month |
| `W` | Nearest weekday | `0 0 15W * *` | Weekday nearest to 15th |
| `#` | Nth occurrence | `0 0 * * 5#3` | Third Friday |

---

## Predefined Schedules

| Shorthand | Equivalent | Description |
|-----------|-----------|-------------|
| `@reboot` | *(none)* | Once at startup |
| `@yearly` | `0 0 1 1 *` | Midnight, January 1 |
| `@monthly` | `0 0 1 * *` | Midnight, 1st of month |
| `@weekly` | `0 0 * * 0` | Midnight, Sunday |
| `@daily` | `0 0 * * *` | Midnight daily |
| `@hourly` | `0 * * * *` | Top of every hour |

---

## Common Patterns — Visual Timeline

### Every 5 Minutes
```
Expression: */5 * * * *

Hour: |----|----|----|----|----|----|----|----|----|----|----|----|
Min:  00   05   10   15   20   25   30   35   40   45   50   55
       ▲    ▲    ▲    ▲    ▲    ▲    ▲    ▲    ▲    ▲    ▲    ▲
```

### Every 15 Minutes
```
Expression: */15 * * * *

Hour: |---------|---------|---------|---------|
Min:  00        15        30        45
       ▲         ▲         ▲         ▲
```

### Twice Daily (8 AM and 8 PM)
```
Expression: 0 8,20 * * *

Day:  |--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|
Hour: 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23
                                 ▲                                  ▲
```

### Business Hours Only (Every 30 Min, 9-17 Mon-Fri)
```
Expression: */30 9-17 * * 1-5

Day:  |--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|
Hour: 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23
                                    ▲▲ ▲▲ ▲▲ ▲▲ ▲▲ ▲▲ ▲▲ ▲▲ ▲▲
                                    Only Mon-Fri

Week: Mon Tue Wed Thu Fri Sat Sun
       ▲   ▲   ▲   ▲   ▲   ·   ·
```

### Daily at 2:30 AM
```
Expression: 30 2 * * *

Day:  |--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|
Hour: 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23
                  ▲
               (2:30)
```

### Weekly Sunday at 3 AM
```
Expression: 0 3 * * 0

Week: Mon Tue Wed Thu Fri Sat Sun
       ·   ·   ·   ·   ·   ·   ▲ (3:00 AM)
```

### Monthly 1st at Midnight
```
Expression: 0 0 1 * *

Month: | 1 | 2 | 3 | ... | 28| 29| 30| 31|
        ▲
     (midnight)
```

---

## Quick Reference Table

| Schedule | Expression | Runs per day | Runs per month |
|----------|-----------|-------------|---------------|
| Every minute | `* * * * *` | 1,440 | ~43,200 |
| Every 5 minutes | `*/5 * * * *` | 288 | ~8,640 |
| Every 15 minutes | `*/15 * * * *` | 96 | ~2,880 |
| Every 30 minutes | `*/30 * * * *` | 48 | ~1,440 |
| Every hour | `0 * * * *` | 24 | ~720 |
| Every 2 hours | `0 */2 * * *` | 12 | ~360 |
| Every 6 hours | `0 */6 * * *` | 4 | ~120 |
| Every 12 hours | `0 0,12 * * *` | 2 | ~60 |
| Daily | `0 0 * * *` | 1 | ~30 |
| Weekdays | `0 9 * * 1-5` | 1 (weekdays) | ~22 |
| Weekly | `0 0 * * 0` | — | ~4 |
| Bi-weekly | *(needs script)* | — | ~2 |
| Monthly | `0 0 1 * *` | — | 1 |
| Quarterly | `0 0 1 1,4,7,10 *` | — | 0.33 |
| Yearly | `0 0 1 1 *` | — | 0.083 |

---

## Day and Month Names

### Days of Week
| Number | 3-letter | Full |
|--------|----------|------|
| 0 or 7 | SUN | Sunday |
| 1 | MON | Monday |
| 2 | TUE | Tuesday |
| 3 | WED | Wednesday |
| 4 | THU | Thursday |
| 5 | FRI | Friday |
| 6 | SAT | Saturday |

### Months
| Number | 3-letter | Full |
|--------|----------|------|
| 1 | JAN | January |
| 2 | FEB | February |
| 3 | MAR | March |
| 4 | APR | April |
| 5 | MAY | May |
| 6 | JUN | June |
| 7 | JUL | July |
| 8 | AUG | August |
| 9 | SEP | September |
| 10 | OCT | October |
| 11 | NOV | November |
| 12 | DEC | December |

---

## Gotchas to Remember

```
⚠ Both dom AND dow set?  → They are ORed, not ANDed
⚠ Using % in crontab?   → Escape as \% (% = newline in crontab)
⚠ No trailing newline?   → Last line may be silently ignored
⚠ Using relative paths?  → Cron PATH is minimal — use absolute paths
⚠ DST transition hours?  → Avoid scheduling at 1-3 AM local time
⚠ System vs user format? → /etc/cron.d has USER field; crontab -e does not
```

---

## Platform Differences

```
                   Unix    Quartz   AWS         GCP
Fields:            5       6-7      6(+year)    5
Seconds:           ✗       ✓        ✗           ✗
? character:       ✗       ✓        ✓           ✗
L (last):          ✗       ✓        ✓           ✗
W (weekday):       ✗       ✓        ✓           ✗
# (nth):           ✗       ✓        ✓           ✗
Timezone:          System  JVM      UTC/config  Config
Wrapper syntax:    none    none     cron(...)   none
```
