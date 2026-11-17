//! Quote chart levels use NY session boundaries, independent of chart bar size.

use ibapi::Client;
use ibapi::market_data::TradingHours;
use ibapi::market_data::historical::{BarSize, Duration, WhatToShow};
use jiff::{Timestamp, civil::Date};
use time::OffsetDateTime;

use crate::session::price_bar;
use crate::strategy::eastern;
use crate::types::{ChartPriceRange, ChartSessionLevels, IbkrError, Instrument, PriceBar};

fn invalid(message: impl ToString) -> IbkrError {
    IbkrError::Invalid { message: message.to_string() }
}

fn date_at(seconds: i64) -> Result<Date, IbkrError> {
    Ok(Timestamp::from_second(seconds).map_err(invalid)?.to_zoned(eastern()).date())
}

fn at(date: Date, hour: i8, minute: i8) -> i64 {
    // These daytime boundaries are never inside a NY DST gap or fold.
    date.at(hour, minute, 0, 0).to_zoned(eastern()).expect("valid NY session boundary").timestamp().as_second()
}

pub(crate) async fn load(client: &Client, instrument: &Instrument, session_time: i64) -> Result<ChartSessionLevels, IbkrError> {
    let date = date_at(session_time)?;
    let now = Timestamp::now().as_second();
    if at(date, 0, 0) > now {
        return Err(invalid("Chart session is in the future"));
    }
    let contract = crate::search::contract(instrument);
    let end = OffsetDateTime::from_unix_timestamp(now.min(at(date, 10, 0))).map_err(invalid)?;
    let previous_end = OffsetDateTime::from_unix_timestamp(at(date, 0, 0)).map_err(invalid)?;
    // Keep requests small. A whole day of minute bars includes 04:00–10:00 even
    // across DST changes. Daily RTH bars skip weekends/holidays and respect early closes.
    let (intraday, previous) = tokio::join!(
        client.historical_data(&contract, BarSize::Min)
            .duration(Duration::days(1)).ending(end)
            .what_to_show(WhatToShow::Trades).trading_hours(TradingHours::Extended).fetch(),
        client.historical_data(&contract, BarSize::Day)
            .duration(Duration::months(1)).ending(previous_end)
            .what_to_show(WhatToShow::Trades).trading_hours(TradingHours::Regular).fetch(),
    );
    let intraday_error = intraday.as_ref().err().map(ToString::to_string);
    let previous_day_error = previous.as_ref().err().map(ToString::to_string);
    let minutes = intraday.map(|data| data.bars.iter().map(price_bar).collect::<Vec<_>>()).unwrap_or_default();
    let daily = previous.map(|data| data.bars.iter().map(price_bar).collect::<Vec<_>>()).unwrap_or_default();
    let mut levels = calculate(date, now, &minutes, &daily);
    levels.intraday_error = intraday_error;
    levels.previous_day_error = previous_day_error;
    Ok(levels)
}

fn valid(bar: &PriceBar) -> bool {
    bar.high.is_finite() && bar.low.is_finite() && bar.high >= bar.low && bar.low > 0.0
}

fn range<'a>(bars: impl Iterator<Item = &'a PriceBar>) -> Option<ChartPriceRange> {
    bars.filter(|b| valid(b)).fold(None, |range, b| {
        Some(match range {
            None => ChartPriceRange { high: b.high, low: b.low },
            Some(r) => ChartPriceRange { high: r.high.max(b.high), low: r.low.min(b.low) },
        })
    })
}

fn calculate(date: Date, now: i64, minutes: &[PriceBar], daily: &[PriceBar]) -> ChartSessionLevels {
    let window = |start, end| range(minutes.iter().filter(|b| {
        b.time >= start && b.time < end && b.time + 60 <= now
    }));
    let open = at(date, 9, 30);
    let previous = daily.iter().filter(|b| valid(b) && date_at(b.time).is_ok_and(|d| d < date)).max_by_key(|b| b.time);
    ChartSessionLevels {
        session_date: date.to_string(),
        previous_session_date: previous.and_then(|b| date_at(b.time).ok()).map(|d| d.to_string()),
        premarket: window(at(date, 4, 0), open),
        orb15: (now >= at(date, 9, 45)).then(|| window(open, at(date, 9, 45))).flatten(),
        orb30: (now >= at(date, 10, 0)).then(|| window(open, at(date, 10, 0))).flatten(),
        previous_day: previous.map(|b| ChartPriceRange { high: b.high, low: b.low }),
        as_of: now,
        intraday_error: None,
        previous_day_error: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::date;

    fn bar(date: Date, hour: i8, minute: i8, low: f64, high: f64) -> PriceBar {
        PriceBar { time: at(date, hour, minute), open: low, high, low, close: high, volume: 1.0 }
    }

    #[test]
    fn exact_session_boundaries_use_high_low_not_close() {
        let d = date(2026, 11, 17);
        let bars = vec![
            bar(d, 3, 59, 1.0, 999.0),
            bar(d, 4, 0, 95.0, 105.0),
            bar(d, 9, 29, 94.0, 106.0),
            bar(d, 9, 30, 97.0, 103.0),
            bar(d, 9, 44, 96.0, 104.0),
            bar(d, 9, 45, 93.0, 107.0),
            bar(d, 9, 59, 92.0, 108.0),
            bar(d, 10, 0, 2.0, 998.0),
            bar(date(2026, 11, 16), 9, 30, 3.0, 997.0),
        ];
        let levels = calculate(d, at(d, 16, 0), &bars, &[]);
        assert_eq!(levels.premarket, Some(ChartPriceRange { low: 94.0, high: 106.0 }));
        assert_eq!(levels.orb15, Some(ChartPriceRange { low: 96.0, high: 104.0 }));
        assert_eq!(levels.orb30, Some(ChartPriceRange { low: 92.0, high: 108.0 }));
    }

    #[test]
    fn opening_ranges_wait_until_complete_and_ignore_future_bars() {
        let d = date(2026, 7, 6);
        let bars = vec![bar(d, 9, 29, 90.0, 110.0), bar(d, 9, 30, 95.0, 105.0), bar(d, 9, 45, 80.0, 120.0)];
        let before = calculate(d, at(d, 9, 29), &bars, &[]);
        assert!(before.premarket.is_none()); // 09:29 minute is still forming.
        let forming = calculate(d, at(d, 9, 44), &bars, &[]);
        assert!(forming.orb15.is_none());
        assert!(forming.orb30.is_none());
        let first = calculate(d, at(d, 9, 45), &bars, &[]);
        assert_eq!(first.orb15.unwrap().high, 105.0);
        assert!(first.orb30.is_none());
        assert_eq!(calculate(d, at(d, 10, 0), &bars, &[]).orb30.unwrap().high, 120.0);
    }

    #[test]
    fn previous_session_skips_holidays_weekends_and_excludes_current_day() {
        // July 3 is the observed Independence Day holiday in 2026.
        let d = date(2026, 7, 6);
        let daily = vec![
            bar(date(2026, 7, 1), 12, 0, 80.0, 120.0),
            bar(date(2026, 7, 2), 12, 0, 95.0, 105.0),
            bar(d, 12, 0, 1.0, 999.0),
        ];
        let levels = calculate(d, at(d, 16, 0), &[], &daily);
        assert_eq!(levels.previous_session_date.as_deref(), Some("2026-07-02"));
        assert_eq!(levels.previous_day, Some(ChartPriceRange { low: 95.0, high: 105.0 }));
    }

    #[test]
    fn ny_boundaries_follow_dst_instead_of_fixed_utc_offset() {
        let winter = date(2026, 11, 2);
        let summer = date(2026, 3, 9);
        for (d, utc_hour) in [(winter, 14), (summer, 13)] {
            let open = Timestamp::from_second(at(d, 9, 30)).unwrap().to_zoned(jiff::tz::TimeZone::UTC);
            assert_eq!(open.hour(), utc_hour);
            let levels = calculate(d, at(d, 10, 0), &[bar(d, 9, 30, 99.0, 101.0)], &[]);
            assert_eq!(levels.orb15.unwrap().high, 101.0);
        }
    }

    #[test]
    fn no_data_and_invalid_prices_never_make_zero_or_nan_levels() {
        let d = date(2026, 11, 17);
        let bars = vec![bar(d, 4, 0, 0.0, 0.0), bar(d, 9, 30, 100.0, f64::NAN), bar(d, 9, 35, 110.0, 100.0)];
        let levels = calculate(d, at(d, 16, 0), &bars, &[]);
        assert!(levels.premarket.is_none());
        assert!(levels.orb15.is_none());
        assert!(levels.orb30.is_none());
        assert!(levels.previous_day.is_none());
    }
}
