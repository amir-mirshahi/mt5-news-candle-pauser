//+------------------------------------------------------------------+
//|                                               NewsFilterDemo.mq5 |
//|                       mt5-news-candle-pauser :: usage example EA |
//+------------------------------------------------------------------+
//| Minimal EA showing how to integrate CNewsFilter into a strategy. |
//| It contains NO trading logic: the marked spot in OnTick() is     |
//| where your own entry code would go.                              |
//+------------------------------------------------------------------+
#property copyright   "mt5-news-candle-pauser"
#property version     "1.00"
#property description "Pauses new entries around high-impact news events."

#include "NewsFilter.mqh"

//--- What the EA does while a news window is active
enum ENUM_NEWS_ACTION
  {
   NEWS_ACTION_ALERT_ONLY    = 0,   // Alert only (trading continues)
   NEWS_ACTION_PAUSE_TRADING = 1    // Pause new entries
  };

//--- Inputs
input string           InpUrl           = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"; // Calendar URL
input int              InpMinutesBefore = 15;                    // Pause X minutes before news
input int              InpMinutesAfter  = 15;                    // Pause X minutes after news
input ENUM_NEWS_IMPACT InpMinImpact     = NEWS_IMPACT_HIGH;      // Minimum impact to react to
input string           InpCurrencies    = "";                    // Currencies (empty = auto from symbol)
input ENUM_NEWS_ACTION InpAction        = NEWS_ACTION_PAUSE_TRADING; // Action during news window

//--- Globals
CNewsFilter g_news;
bool        g_was_blocked = false;   // used to detect state *changes* (alert once, not every tick)

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(MQLInfoInteger(MQL_TESTER))
      Print("NewsFilterDemo: WebRequest is unavailable in the Strategy Tester - no news data will load.");

   g_news.Configure(InpUrl, InpMinutesBefore, InpMinutesAfter, InpMinImpact);

   if(StringLen(InpCurrencies) > 0)
      g_news.SetCurrencies(InpCurrencies);
   else
      g_news.SetCurrenciesFromSymbol(_Symbol);

   if(!EventSetTimer(30))
      return INIT_FAILED;

   g_news.Update(true);   // initial fetch (forced)
   RefreshState();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

//+------------------------------------------------------------------+
//| Timer: network refresh + state-change notifications              |
//| Update() throttles itself, so calling it every 30 s is cheap.    |
//+------------------------------------------------------------------+
void OnTimer()
  {
   g_news.Update();
   RefreshState();
  }

//+------------------------------------------------------------------+
//| Tick: cache-only check, safe to run on every tick                |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(InpAction == NEWS_ACTION_PAUSE_TRADING && g_news.IsTradingBlocked())
      return;   // news window active: skip new entries

   //--- >>> your strategy's entry logic goes here <<<
  }

//+------------------------------------------------------------------+
//| Detect pause start/end, alert once, and update the chart panel   |
//+------------------------------------------------------------------+
void RefreshState()
  {
   SNewsEvent active;
   bool blocked = g_news.IsTradingBlocked(active);

   if(blocked && !g_was_blocked)
      Alert(StringFormat("NEWS WINDOW STARTED: %s %s (%s impact) at %s UTC",
                         active.currency, active.title,
                         NewsImpactToString(active.impact),
                         TimeToString(active.time_utc, TIME_DATE | TIME_MINUTES)));

   if(!blocked && g_was_blocked)
      Print("NewsFilterDemo: news window ended, trading resumed.");

   g_was_blocked = blocked;

   //--- simple status panel
   string text = "News filter: " + (blocked ? "PAUSED" : "active") + "\n";
   text += StringFormat("Events cached: %d\n", g_news.EventCount());

   SNewsEvent next;
   if(g_news.GetNextEvent(next))
      text += StringFormat("Next: %s %s (%s) at %s UTC",
                           next.currency, next.title,
                           NewsImpactToString(next.impact),
                           TimeToString(next.time_utc, TIME_DATE | TIME_MINUTES));
   else
      text += "Next: none this week";

   Comment(text);
  }
//+------------------------------------------------------------------+