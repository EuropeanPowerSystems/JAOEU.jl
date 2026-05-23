using Dates: Dates, DateTime, Date
using TimeZones: TimeZones, ZonedDateTime

const _UTC = TimeZones.tz"UTC"

"""
    to_zoned_utc(t) -> ZonedDateTime

Coerce `t` to a UTC `ZonedDateTime` for use as `from_utc` / `to_utc` in the
generated API functions. The Publication Tool accepts ISO 8601 with an
offset (which is what OpenAPI emits for `ZonedDateTime`), so as long as
the value is in UTC the wire format matches what JAO expects.

Accepted inputs:

  - `ZonedDateTime` — converted to UTC if necessary.
  - `DateTime` — interpreted as UTC (no implicit local-zone guess).
  - `Date` — promoted to `00:00:00` UTC of that day.
"""
to_zoned_utc(t::ZonedDateTime) = TimeZones.astimezone(t, _UTC)
to_zoned_utc(t::DateTime) = ZonedDateTime(t, _UTC)
to_zoned_utc(t::Date) = ZonedDateTime(DateTime(t), _UTC)
