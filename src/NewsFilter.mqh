//+------------------------------------------------------------------+
//|                                                   NewsFilter.mqh |
//|                       mt5-news-candle-pauser :: News Filter core |
//+------------------------------------------------------------------+
//| Fetches an economic calendar over HTTP (WebRequest), caches it,  |
//| and tells the caller whether trading should be paused because a  |
//| relevant news event is within N minutes before / after.          |
//|                                                                  |
//| Design notes                                                     |
//|  - All comparisons are done in UTC (TimeGMT) so broker server    |
//|    time zones and DST never leak into the logic.                 |
//|  - Network I/O is isolated from the blocking decision:           |
//|    Update() talks to the network, IsTradingBlocked() only reads  |
//|    the in-memory cache and is cheap enough to call on every tick.|
//|  - No external JSON library: the feed is a flat array of objects, |
//|    so a small purpose-built extractor is enough.                 |
//+------------------------------------------------------------------+
#ifndef MT5_NEWS_FILTER_MQH
#define MT5_NEWS_FILTER_MQH

//--- Impact levels, ordered so they can be compared with >=
enum ENUM_NEWS_IMPACT
  {
   NEWS_IMPACT_NONE   = 0,   // holidays / unknown
   NEWS_IMPACT_LOW    = 1,
   NEWS_IMPACT_MEDIUM = 2,
   NEWS_IMPACT_HIGH   = 3
  };

//--- One calendar entry, normalised to UTC
struct SNewsEvent
  {
   datetime          time_utc;   // event time in UTC
   string            title;      // e.g. "Non-Farm Employment Change"
   string            currency;   // e.g. "USD"
   ENUM_NEWS_IMPACT  impact;
  };

//+------------------------------------------------------------------+
//| Human-readable impact label (used for logs and alerts)           |
//+------------------------------------------------------------------+
string NewsImpactToString(const ENUM_NEWS_IMPACT impact)
  {
   switch(impact)
     {
      case NEWS_IMPACT_HIGH:   return "High";
      case NEWS_IMPACT_MEDIUM: return "Medium";
      case NEWS_IMPACT_LOW:    return "Low";
      default:                 return "None";
     }
  }

//+------------------------------------------------------------------+
//| CNewsFilter                                                      |
//+------------------------------------------------------------------+
class CNewsFilter
  {
private:
   //--- configuration
   string            m_url;              // calendar endpoint
   int               m_minutes_before;   // pause window before event
   int               m_minutes_after;    // pause window after event
   ENUM_NEWS_IMPACT  m_min_impact;       // minimum impact that triggers a pause
   string            m_currencies[];     // watched currencies (empty = all)
   int               m_timeout_ms;       // WebRequest timeout
   int               m_refresh_secs;     // normal refresh interval
   int               m_retry_secs;       // retry interval after a failure

   //--- state
   SNewsEvent        m_events[];         // cached calendar
   datetime          m_last_attempt;     // last fetch attempt (UTC)
   datetime          m_last_success;     // last successful fetch (UTC)

   //--- shared cache + rate-limit protection (shared by all charts and restarts)
   string            m_cache_file;       // stored in the terminal's Common\Files folder
   bool              LoadCache(string &body, const bool ignore_age);
   void              SaveCache(const string body);
   bool              UseStaleCache();    // last resort: old data beats no data
   bool              InBackoff();
   void              StartBackoff(const int seconds);

   //--- network + parsing (all private: callers never see raw JSON)
   bool              Download(string &body, int &status);
   bool              Parse(const string &json);
   bool              ParseEvent(const string &obj, SNewsEvent &ev);
   string            ExtractString(const string &obj, const string key);
   ENUM_NEWS_IMPACT  ParseImpact(const string text);
   bool              ParseIsoTime(const string iso, datetime &utc);

   //--- filtering
   bool              IsWatchedCurrency(const string currency);
   bool              IsRelevant(const SNewsEvent &ev);

public:
                     CNewsFilter();

   //--- configuration (call once, typically from OnInit)
   void              Configure(const string url,
                               const int minutes_before,
                               const int minutes_after,
                               const ENUM_NEWS_IMPACT min_impact);
   void              SetCurrencies(const string csv);              // "USD,EUR"
   void              SetCurrenciesFromSymbol(const string symbol); // EURUSD -> EUR,USD
   void              SetRefreshIntervals(const int refresh_secs, const int retry_secs);

   //--- data refresh (call from OnTimer, NOT from OnTick)
   bool              Update(const bool force = false);

   //--- decisions (cheap, cache-only)
   bool              IsTradingBlocked(SNewsEvent &active_event);
   bool              IsTradingBlocked();
   bool              GetNextEvent(SNewsEvent &next_event);

   //--- diagnostics
   int               EventCount() const { return ArraySize(m_events); }
   datetime          LastSuccess() const { return m_last_success; }
  };

//+------------------------------------------------------------------+
//| Constructor: safe, conservative defaults                         |
//+------------------------------------------------------------------+
CNewsFilter::CNewsFilter()
  {
   m_url            = "";
   m_minutes_before = 15;
   m_minutes_after  = 15;
   m_min_impact     = NEWS_IMPACT_HIGH;
   m_timeout_ms     = 5000;
   m_refresh_secs   = 3600;   // calendar rarely changes: hourly is plenty
   m_retry_secs     = 300;    // after a failure, retry every 5 min
   m_cache_file     = "NewsFilter_calendar_cache.bin";
   m_last_attempt   = 0;
   m_last_success   = 0;
  }

//+------------------------------------------------------------------+
//| Configure endpoint, window size and impact threshold             |
//+------------------------------------------------------------------+
void CNewsFilter::Configure(const string url,
                            const int minutes_before,
                            const int minutes_after,
                            const ENUM_NEWS_IMPACT min_impact)
  {
   m_url            = url;
   m_minutes_before = MathMax(0, minutes_before);
   m_minutes_after  = MathMax(0, minutes_after);
   m_min_impact     = min_impact;
  }

//+------------------------------------------------------------------+
//| Watch an explicit currency list, e.g. "USD,EUR,GBP"              |
//| An empty string means "watch everything".                        |
//+------------------------------------------------------------------+
void CNewsFilter::SetCurrencies(const string csv)
  {
   ArrayResize(m_currencies, 0);
   if(StringLen(csv) == 0)
      return;

   StringSplit(csv, ',', m_currencies);
   for(int i = 0; i < ArraySize(m_currencies); i++)
     {
      StringTrimLeft(m_currencies[i]);
      StringTrimRight(m_currencies[i]);
      StringToUpper(m_currencies[i]);
     }
  }

//+------------------------------------------------------------------+
//| Derive watched currencies from a symbol's base and profit ccy    |
//+------------------------------------------------------------------+
void CNewsFilter::SetCurrenciesFromSymbol(const string symbol)
  {
   string base   = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
   string profit = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   SetCurrencies(base + "," + profit);
  }

//+------------------------------------------------------------------+
//| Tune how often the calendar is fetched                           |
//+------------------------------------------------------------------+
void CNewsFilter::SetRefreshIntervals(const int refresh_secs, const int retry_secs)
  {
   m_refresh_secs = MathMax(60, refresh_secs);   // never hammer the API
   m_retry_secs   = MathMax(60, retry_secs);
  }

//+------------------------------------------------------------------+
//| Refresh the cache if it is stale.                                |
//| Returns true if usable data is available afterwards.             |
//| On failure the OLD cache is kept, so a flaky connection does not |
//| silently remove protection.                                      |
//+------------------------------------------------------------------+
bool CNewsFilter::Update(const bool force = false)
  {
   datetime now = TimeGMT();

   if(!force && m_last_attempt > 0)
     {
      bool last_ok = (m_last_success >= m_last_attempt);
      int  wait    = last_ok ? m_refresh_secs : m_retry_secs;
      if(now - m_last_attempt < wait)
         return (ArraySize(m_events) > 0);   // not due yet
     }

   m_last_attempt = now;
   string body;

   //--- 1) Fresh shared cache (written by any chart or an earlier session)?
   if(LoadCache(body, false) && Parse(body))
     {
      m_last_success = now;
      PrintFormat("CNewsFilter: loaded %d events from shared cache", ArraySize(m_events));
      return true;
     }

   //--- 2) Server asked us to slow down (HTTP 429): don't touch the network
   if(InBackoff())
      return UseStaleCache();

   //--- 3) Another chart started a download moments ago: wait for its cache.
   //       (Best-effort lock; resetting m_last_attempt makes the next timer retry soon.)
   const string lock_name = "NewsFilter_FetchLock";
   if(GlobalVariableCheck(lock_name) && now - (datetime)GlobalVariableGet(lock_name) < 20)
     {
      m_last_attempt = 0;
      return UseStaleCache();
     }
   GlobalVariableSet(lock_name, (double)now);

   //--- 4) Download for real
   int status = 0;
   if(!Download(body, status))
     {
      if(status == 429)
         StartBackoff(1800);   // 30 minutes
      return UseStaleCache();
     }

   if(!Parse(body))
      return UseStaleCache();

   SaveCache(body);
   m_last_success = now;
   PrintFormat("CNewsFilter: calendar downloaded, %d events cached", ArraySize(m_events));
   return true;
  }

//+------------------------------------------------------------------+
//| Read the shared cache file. Layout: [long saved_utc][int len][text]|
//| ignore_age = true accepts an expired cache (fallback use only).  |
//+------------------------------------------------------------------+
bool CNewsFilter::LoadCache(string &body, const bool ignore_age)
  {
   int h = FileOpen(m_cache_file, FILE_READ | FILE_BIN | FILE_COMMON |
                                  FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
      return false;

   datetime saved = (datetime)FileReadLong(h);
   int      len   = FileReadInteger(h, INT_VALUE);

   bool fresh = (len > 0 && (ignore_age || TimeGMT() - saved <= m_refresh_secs));
   if(fresh)
      body = FileReadString(h, len);
   FileClose(h);

   return (fresh && StringLen(body) == len);   // length check guards against half-written files
  }

//+------------------------------------------------------------------+
//| Write the shared cache file (timestamp + length + JSON text)     |
//+------------------------------------------------------------------+
void CNewsFilter::SaveCache(const string body)
  {
   int h = FileOpen(m_cache_file, FILE_WRITE | FILE_BIN | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("CNewsFilter: cannot write cache file, error %d", GetLastError());
      return;
     }
   FileWriteLong(h, (long)TimeGMT());
   FileWriteInteger(h, StringLen(body), INT_VALUE);
   FileWriteString(h, body);
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Failure path: if memory is empty, load the (possibly old) file   |
//| so protection continues. Returns true if any events are cached.  |
//+------------------------------------------------------------------+
bool CNewsFilter::UseStaleCache()
  {
   if(ArraySize(m_events) == 0)
     {
      string body;
      if(LoadCache(body, true))
         Parse(body);
     }
   return (ArraySize(m_events) > 0);
  }

//+------------------------------------------------------------------+
//| Shared (terminal-wide) "do not call the API until..." marker     |
//+------------------------------------------------------------------+
bool CNewsFilter::InBackoff()
  {
   const string name = "NewsFilter_BackoffUntil";
   if(!GlobalVariableCheck(name))
      return false;
   return (TimeGMT() < (datetime)GlobalVariableGet(name));
  }

void CNewsFilter::StartBackoff(const int seconds)
  {
   GlobalVariableSet("NewsFilter_BackoffUntil", (double)(TimeGMT() + seconds));
   PrintFormat("CNewsFilter: rate limited (HTTP 429) - pausing downloads for %d min", seconds / 60);
  }

//+------------------------------------------------------------------+
//| True if "now" is inside the pause window of a relevant event.    |
//| The triggering event is returned in active_event.                |
//+------------------------------------------------------------------+
bool CNewsFilter::IsTradingBlocked(SNewsEvent &active_event)
  {
   datetime now = TimeGMT();

   for(int i = 0; i < ArraySize(m_events); i++)
     {
      if(!IsRelevant(m_events[i]))
         continue;

      datetime window_start = m_events[i].time_utc - m_minutes_before * 60;
      datetime window_end   = m_events[i].time_utc + m_minutes_after  * 60;

      if(now >= window_start && now <= window_end)
        {
         active_event = m_events[i];
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Convenience overload when the caller doesn't need the details    |
//+------------------------------------------------------------------+
bool CNewsFilter::IsTradingBlocked()
  {
   SNewsEvent ignored;
   return IsTradingBlocked(ignored);
  }

//+------------------------------------------------------------------+
//| Soonest upcoming relevant event (useful for dashboards/alerts)   |
//+------------------------------------------------------------------+
bool CNewsFilter::GetNextEvent(SNewsEvent &next_event)
  {
   datetime now   = TimeGMT();
   bool     found = false;

   for(int i = 0; i < ArraySize(m_events); i++)
     {
      if(!IsRelevant(m_events[i]) || m_events[i].time_utc < now)
         continue;

      if(!found || m_events[i].time_utc < next_event.time_utc)
        {
         next_event = m_events[i];
         found      = true;
        }
     }
   return found;
  }

//+------------------------------------------------------------------+
//| HTTP GET -> raw response body                                    |
//+------------------------------------------------------------------+
bool CNewsFilter::Download(string &body, int &status)
  {
   status = 0;
   if(StringLen(m_url) == 0)
     {
      Print("CNewsFilter: URL not configured. Call Configure() first.");
      return false;
     }

   char   request[];    // empty: GET has no body
   char   response[];
   string response_headers;

   ResetLastError();
   status = WebRequest("GET", m_url, "Accept: application/json\r\n",
                           m_timeout_ms, request, response, response_headers);

   if(status == -1)
     {
      int err = GetLastError();
      PrintFormat("CNewsFilter: WebRequest failed, error %d", err);
      if(err == 4060)
         PrintFormat("CNewsFilter: add %s to Tools > Options > Expert Advisors > Allow WebRequest", m_url);
      return false;
     }

   if(status != 200)
     {
      PrintFormat("CNewsFilter: HTTP status %d (expected 200)", status);
      return false;
     }

   body = CharArrayToString(response, 0, WHOLE_ARRAY, CP_UTF8);
   return (StringLen(body) > 0);
  }

//+------------------------------------------------------------------+
//| Walk the JSON array object by object and rebuild the cache.      |
//| The cache is only replaced if at least one event was parsed.     |
//| Limitation: assumes flat objects without braces inside strings.  |
//+------------------------------------------------------------------+
bool CNewsFilter::Parse(const string &json)
  {
   SNewsEvent parsed[];
   int count = 0;
   int pos   = 0;

   while(true)
     {
      int open = StringFind(json, "{", pos);
      if(open < 0)
         break;
      int close = StringFind(json, "}", open);
      if(close < 0)
         break;

      string obj = StringSubstr(json, open, close - open + 1);
      pos = close + 1;

      SNewsEvent ev;
      if(!ParseEvent(obj, ev))
         continue;   // skip malformed entries instead of failing the whole feed

      ArrayResize(parsed, count + 1);
      parsed[count] = ev;
      count++;
     }

   if(count == 0)
     {
      Print("CNewsFilter: no events parsed, keeping previous cache");
      return false;
     }

   ArrayResize(m_events, count);
   for(int i = 0; i < count; i++)
      m_events[i] = parsed[i];
   return true;
  }

//+------------------------------------------------------------------+
//| One JSON object -> SNewsEvent                                    |
//+------------------------------------------------------------------+
bool CNewsFilter::ParseEvent(const string &obj, SNewsEvent &ev)
  {
   ev.title    = ExtractString(obj, "title");
   ev.currency = ExtractString(obj, "country");
   ev.impact   = ParseImpact(ExtractString(obj, "impact"));
   StringToUpper(ev.currency);

   return ParseIsoTime(ExtractString(obj, "date"), ev.time_utc);
  }

//+------------------------------------------------------------------+
//| Value of a string field: "key": "value"  ->  value               |
//+------------------------------------------------------------------+
string CNewsFilter::ExtractString(const string &obj, const string key)
  {
   string needle = "\"" + key + "\"";

   int k = StringFind(obj, needle);
   if(k < 0)
      return "";

   int colon = StringFind(obj, ":", k + StringLen(needle));
   if(colon < 0)
      return "";

   int q1 = StringFind(obj, "\"", colon + 1);
   if(q1 < 0)
      return "";

   int q2 = StringFind(obj, "\"", q1 + 1);
   if(q2 < 0)
      return "";

   return StringSubstr(obj, q1 + 1, q2 - q1 - 1);
  }

//+------------------------------------------------------------------+
//| "High" / "Medium" / "Low" -> enum (anything else -> NONE)        |
//+------------------------------------------------------------------+
ENUM_NEWS_IMPACT CNewsFilter::ParseImpact(const string text)
  {
   string t = text;
   StringToUpper(t);

   if(t == "HIGH")   return NEWS_IMPACT_HIGH;
   if(t == "MEDIUM") return NEWS_IMPACT_MEDIUM;
   if(t == "LOW")    return NEWS_IMPACT_LOW;
   return NEWS_IMPACT_NONE;
  }

//+------------------------------------------------------------------+
//| ISO-8601 with offset ("2026-10-30T08:30:00-04:00") -> UTC        |
//| Also accepts a trailing "Z" (already UTC).                       |
//+------------------------------------------------------------------+
bool CNewsFilter::ParseIsoTime(const string iso, datetime &utc)
  {
   if(StringLen(iso) < 19)
      return false;

   string date_part = StringSubstr(iso, 0, 10);        // 2026-10-30
   StringReplace(date_part, "-", ".");                 // 2026.10.30
   string time_part = StringSubstr(iso, 11, 8);        // 08:30:00

   datetime local = StringToTime(date_part + " " + time_part);
   if(local <= 0)
      return false;

   int offset_secs = 0;
   if(StringLen(iso) >= 25)
     {
      ushort sign = StringGetCharacter(iso, 19);       // '+' or '-'
      int hh = (int)StringToInteger(StringSubstr(iso, 20, 2));
      int mm = (int)StringToInteger(StringSubstr(iso, 23, 2));
      offset_secs = hh * 3600 + mm * 60;
      if(sign == '-')
         offset_secs = -offset_secs;
     }

   utc = local - offset_secs;   // local = UTC + offset  =>  UTC = local - offset
   return true;
  }

//+------------------------------------------------------------------+
//| Is this currency on our watch list? (empty list = all)           |
//+------------------------------------------------------------------+
bool CNewsFilter::IsWatchedCurrency(const string currency)
  {
   if(ArraySize(m_currencies) == 0)
      return true;

   for(int i = 0; i < ArraySize(m_currencies); i++)
      if(m_currencies[i] == currency)
         return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Does this event meet our impact + currency criteria?             |
//+------------------------------------------------------------------+
bool CNewsFilter::IsRelevant(const SNewsEvent &ev)
  {
   return (ev.impact >= m_min_impact && IsWatchedCurrency(ev.currency));
  }

#endif // MT5_NEWS_FILTER_MQH