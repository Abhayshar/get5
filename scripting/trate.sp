#include <cstrike>
#include <sdktools>
#include <sourcemod>
#include "include/logdebug.inc"
#include "include/trate.inc"

#undef REQUIRE_EXTENSIONS
#include <smjansson>
#if defined _jansson_included_
#include "include/jsonhelpers.inc"
#endif

#define LIVE_TIMER_INTERVAL 1.0
#define INFO_MESSAGE_TIMER_INTERVAL 29.0

#define DEBUG_CVAR "trate_debug"
#define AUTH_LENGTH 64
#define AUTH_METHOD AuthId_Steam2
#define MATCH_ID_LENGTH 64
#define MATCH_NAME_LENGTH 64
#define TEAM_NAME_LENGTH 64
#define TEAM_FLAG_LENGTH 4
#define TEAM_LOGO_LENGTH 64
#define MAX_CVAR_LENGTH 128
#define MATCH_END_DELAY_AFTER_TV 10

#define TEAM1_COLOR "{LIGHT_RED}"
#define TEAM2_COLOR "{PINK}"
#define TEAM1_STARTING_SIDE CS_TEAM_CT
#define TEAM2_STARTING_SIDE CS_TEAM_T

#define LIVE_CONFIG "trate/live.cfg"
#define KNIFE_CONFIG "trate/knife.cfg"
#define WARMUP_CONFIG "trate/warmup.cfg"

#pragma semicolon 1
#pragma newdecls required



/***********************
 *                     *
 *   Global variables  *
 *                     *
 ***********************/

/** ConVar handles **/
ConVar g_AutoLoadConfigCvar;
ConVar g_VersionCvar;
ConVar g_DemoNameFormatCvar;
ConVar g_DemoTimeFormatCvar;
ConVar g_PausingEnabledCvar;

/** Series config game-state **/
int g_MapsToWin = 1;
char g_MatchID[MATCH_ID_LENGTH];
ArrayList g_MapList = null;
ArrayList g_TeamAuths[MatchTeam_Count];
char g_TeamNames[MatchTeam_Count][TEAM_NAME_LENGTH];
char g_FormattedTeamNames[MatchTeam_Count][TEAM_NAME_LENGTH];
char g_TeamFlags[MatchTeam_Count][TEAM_FLAG_LENGTH];
char g_TeamLogos[MatchTeam_Count][TEAM_LOGO_LENGTH];
char g_TeamMatchTexts[MatchTeam_Count][MAX_CVAR_LENGTH];
int g_PlayersPerTeam = 5;
bool g_SkipVeto = false;
ArrayList g_CvarNames = null;
ArrayList g_CvarValues = null;

// Other state
GameState g_GameState = GameState_None;
ArrayList g_MapsToPlay = null;
ArrayList g_MapsLeftInVetoPool = null;
MatchTeam g_LastVetoTeam;

char g_LoadedConfigFile[PLATFORM_MAX_PATH];
int g_VetoCaptains[MatchTeam_Count]; // Clients doing the map vetos.
int g_TeamMapScores[MatchTeam_Count]; // Current number of maps won per-team.
bool g_TeamReady[MatchTeam_Count]; // Whether a team is marked as ready.
int g_TeamSide[MatchTeam_Count]; // Current CS_TEAM_* side for the team.

/** Map game-state **/
MatchTeam g_LastRoundWinner = MatchTeam_TeamNone;
MatchTeam g_KnifeWinnerTeam = MatchTeam_TeamNone;
bool g_ctUnpaused = false;
bool g_tUnpaused = false;

// Map-game state not related to the actual gameplay.
char g_DemoFileName[PLATFORM_MAX_PATH];
bool g_MapChangePending = false;

#include "trate/kniferounds.sp"
#include "trate/liveon3.sp"
#include "trate/maps.sp"
#include "trate/mapveto.sp"
#include "trate/matchconfig.sp"
#include "trate/natives.sp"
#include "trate/util.sp"
#include "trate/teamlogic.sp"



/***********************
 *                     *
 * Sourcemod forwards  *
 *                     *
 ***********************/

public Plugin myinfo = {
    name = "Trate",
    author = "splewis",
    description = "",
    version = PLUGIN_VERSION,
    url = "https://github.com/splewis"
};

public void OnPluginStart() {
    InitDebugLog("sm_trate_debug", "trate");

    /** ConVars **/
    g_AutoLoadConfigCvar = CreateConVar("trate_autoload_config", "", "");
    g_DemoNameFormatCvar = CreateConVar("trate_demo_name_format", "{MATCHID}_map{MAPNUMBER}_{MAPNAME}");
    g_DemoTimeFormatCvar = CreateConVar("trate_time_format", "%Y-%m-%d_%H", "Time format to use when creating demo file names. Don't tweak this unless you know what you're doing! Avoid using spaces or colons.");
    g_PausingEnabledCvar = CreateConVar("trate_pausing_enabled", "1", "Whether pausing is allowed.");

    /** Create and exec plugin's configuration file **/
    AutoExecConfig(true, "trate");

    g_VersionCvar = CreateConVar("trate_version", PLUGIN_VERSION, "Current trate version", FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
    g_VersionCvar.SetString(PLUGIN_VERSION);

    /** Client commands **/
    RegConsoleCmd("sm_ready", Command_Ready, "Marks the client as ready");
    RegConsoleCmd("sm_notready", Command_NotReady, "Marks the client as not ready");
    RegConsoleCmd("sm_pause", Command_Pause, "Pauses the game");
    RegConsoleCmd("sm_unpause", Command_Unpause, "Unpauses the game");
    RegConsoleCmd("sm_stay", Command_Stay, "Elects to stay on the current team after winning a knife round");
    RegConsoleCmd("sm_swap", Command_Swap, "Elects to swap the current teams after winning a knife round");
    RegConsoleCmd("sm_t", Command_T, "Elects to start on T side after winning a knife round");
    RegConsoleCmd("sm_ct", Command_Ct, "Elects to start on CT side after winning a knife round");

    /** Other commands **/
    RegAdminCmd("trate_endmatch", Command_EndMatch, ADMFLAG_CHANGEMAP);
    RegAdminCmd("trate_loadmatch", Command_LoadMatch, ADMFLAG_CHANGEMAP);
    RegConsoleCmd("trate_status", Command_Status);

    /** Hooks **/
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("cs_win_panel_match", Event_MatchOver);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("announce_phase_end", Event_PhaseEnd);
    HookEvent("server_cvar", Event_CvarChanged, EventHookMode_Pre);
    HookEvent("player_connect_full", Event_PlayerConnectFull);
    HookEvent("player_team", Event_OnPlayerTeam, EventHookMode_Pre);
    AddCommandListener(Command_Coach, "coach");
    AddCommandListener(Command_JoinTeam, "jointeam");

    /** Setup data structures **/
    g_MapList = new ArrayList(PLATFORM_MAX_PATH);
    g_MapsLeftInVetoPool = new ArrayList(PLATFORM_MAX_PATH);
    g_MapsToPlay = new ArrayList(PLATFORM_MAX_PATH);
    g_CvarNames = new ArrayList(MAX_CVAR_LENGTH);
    g_CvarValues = new ArrayList(MAX_CVAR_LENGTH);

    for (int i = 0; i < sizeof(g_TeamAuths); i++) {
        g_TeamAuths[i] = new ArrayList(AUTH_LENGTH);
    }

    /** Start any repeating timers **/
    CreateTimer(LIVE_TIMER_INTERVAL, Timer_CheckReady, _, TIMER_REPEAT);
    CreateTimer(INFO_MESSAGE_TIMER_INTERVAL, Timer_InfoMessages, _, TIMER_REPEAT);
}

public Action Timer_InfoMessages(Handle timer) {
    if (g_GameState == GameState_PreVeto) {
        Trate_MessageToAll("Type {GREEN}!ready {NORMAL}when your team is ready to veto.");
    } else if (g_GameState == GameState_Warmup) {
        Trate_MessageToAll("Type {GREEN}!ready {NORMAL}when your team is ready to knife for sides.");
    } else if (g_GameState == GameState_PostGame) {
        Trate_MessageToAll("The map will change once the GOTV broadcast has ended.");
    }
}

public void OnClientAuthorized(int client, const char[] auth) {
    if (StrEqual(auth, "BOT", false)) {
        return;
    }

    if (g_GameState == GameState_None) {
        KickClient(client, "There is no match setup");
    }

    MatchTeam team = GetClientMatchTeam(client);
    if (team == MatchTeam_TeamNone) {
        KickClient(client, "You are not a player in this match");
    }

    if (CountPlayersOnMatchTeam(team) >= g_PlayersPerTeam) {
        // TODO: to enable coaching this probably has to be changed.
        KickClient(client, "Your team is full.");
    }
}

public void OnClientPutInServer(int client) {
    if (IsFakeClient(client)) {
        return;
    }

    if (g_GameState <= GameState_Warmup) {
        if (GetRealClientCount() <= 1) {
            EnsurePausedWarmup();
            ServerCommand("exec %s", WARMUP_CONFIG);
        }
    }
}

/**
 * Full connect event right when a player joins.
 * This sets the auto-pick time to a high value because mp_forcepicktime is broken and
 * if a player does not select a team but leaves their mouse over one, they are
 * put on that team and spawned, so we can't allow that.
 */
public Action Event_PlayerConnectFull(Handle event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    SetEntPropFloat(client, Prop_Send, "m_fForceTeam", 3600.0);
}

public void OnMapStart() {
    g_MapChangePending = false;
    g_TeamReady[MatchTeam_Team1] = false;
    g_TeamReady[MatchTeam_Team2] = false;
    g_TeamSide[MatchTeam_Team1] = TEAM1_STARTING_SIDE;
    g_TeamSide[MatchTeam_Team2] = TEAM2_STARTING_SIDE;

    // ServerCommand("sv_disable_show_team_select_menu 1");

    if (g_GameState == GameState_None) {
        char autoloadConfig[PLATFORM_MAX_PATH];
        g_AutoLoadConfigCvar.GetString(autoloadConfig, sizeof(autoloadConfig));
        if (!StrEqual(autoloadConfig, "")) {
            LoadMatchConfig(autoloadConfig);
        }
    }

    if (g_GameState == GameState_PostGame) {
        ChangeState(GameState_Warmup);
    }

    if (g_GameState == GameState_Warmup || g_GameState == GameState_Veto) {
        ServerCommand("exec %s", WARMUP_CONFIG);
        ExecuteMatchConfigCvars();
        EnsurePausedWarmup();
        SetMatchTeamCvars();
    }

}

public Action Timer_CheckReady(Handle timer) {
    if (g_GameState == GameState_PreVeto) {
        if (AllTeamsReady()) {
            ChangeState(GameState_Veto);
            CreateMapVeto();
        }

    } else  if (g_GameState == GameState_Warmup) {
        if (AllTeamsReady() && !g_MapChangePending) {
            ChangeState(GameState_KnifeRound);
            StartGame();
        }
    }

    return Plugin_Continue;
}


/***********************
 *                     *
 *     Commands        *
 *                     *
 ***********************/

static bool Pauseable() {
    return g_GameState >= GameState_KnifeRound && g_PausingEnabledCvar.IntValue != 0;
}

public Action Command_Pause(int client, int args) {
    if (!Pauseable() || IsPaused())
        return Plugin_Handled;

    g_ctUnpaused = false;
    g_tUnpaused = false;
    Pause();
    if (IsPlayer(client)) {
        Trate_MessageToAll("%N paused the match.", client);
    }

    return Plugin_Handled;
}

public Action Command_Unpause(int client, int args) {
    if (!IsPaused())
        return Plugin_Handled;


    // Let console force unpause
    if (client == 0) {
        Unpause();
    } else {
        int team = GetClientTeam(client);
        if (team == CS_TEAM_T)
            g_tUnpaused = true;
        else if (team == CS_TEAM_CT)
            g_ctUnpaused = true;

        if (g_tUnpaused && g_ctUnpaused)  {
            Unpause();
            if (IsPlayer(client)) {
                Trate_MessageToAll("%N unpaused the match.", client);
            }
        } else if (g_tUnpaused && !g_ctUnpaused) {
            Trate_MessageToAll("The T team wants to unpause, waiting for the CT team to type !unpause.");
        } else if (!g_tUnpaused && g_ctUnpaused) {
            Trate_MessageToAll("The CT team wants to unpause, waiting for the T team to type !unpause.");
        }
    }

    return Plugin_Handled;
}

public Action Command_Ready(int client, int args) {
    MatchTeam t = GetCaptainTeam(client);
    if (t == MatchTeam_Team1 && !g_TeamReady[MatchTeam_Team1]) {
        g_TeamReady[MatchTeam_Team1] = true;
        if (g_GameState == GameState_PreVeto) {
            Trate_MessageToAll("%s is ready to veto.", g_FormattedTeamNames[MatchTeam_Team1]);
        } else {
            Trate_MessageToAll("%s is ready to begin the match.", g_FormattedTeamNames[MatchTeam_Team1]);
        }
    } else if (t == MatchTeam_Team2 && !g_TeamReady[MatchTeam_Team2]) {
        g_TeamReady[MatchTeam_Team2] = true;
        if (g_GameState == GameState_PreVeto) {
            Trate_MessageToAll("%s is ready to veto.", g_FormattedTeamNames[MatchTeam_Team2]);
        } else {
            Trate_MessageToAll("%s is ready to begin the match.", g_FormattedTeamNames[MatchTeam_Team2]);
        }
    }
    return Plugin_Handled;
}

public Action Command_NotReady(int client, int args) {
    MatchTeam t = GetCaptainTeam(client);
    if (t == MatchTeam_Team1 && g_TeamReady[MatchTeam_Team1]) {
        Trate_MessageToAll("%s is no longer ready.", g_FormattedTeamNames[MatchTeam_Team1]);
        g_TeamReady[MatchTeam_Team1] = false;
    } else if (t == MatchTeam_Team2 && g_TeamReady[MatchTeam_Team2]) {
        Trate_MessageToAll("%s is no longer ready.", g_FormattedTeamNames[MatchTeam_Team2]);
        g_TeamReady[MatchTeam_Team2] = false;
    }
    return Plugin_Handled;
}

public Action Command_EndMatch(int client, int args) {
    if (g_GameState == GameState_None) {
        return Plugin_Handled;
    }
    ChangeState(GameState_None);

    Trate_MessageToAll("An admin force ended the match.");
    return Plugin_Handled;
}

public Action Command_LoadMatch(int client, int args) {
    if (g_GameState != GameState_None) {
        return Plugin_Handled;
    }
    char arg[PLATFORM_MAX_PATH];
    if (args >= 1 && GetCmdArg(1, arg, sizeof(arg))) {
        if (!LoadMatchConfig(arg)) {
            ReplyToCommand(client, "Failed to load match config.");
        }
    } else {
        ReplyToCommand(client, "Usage: trate_loadmatch <filename>");
    }

    return Plugin_Handled;
}


/***********************
 *                     *
 *       Events        *
 *                     *
 ***********************/

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    if (g_GameState < GameState_KnifeRound) {
        int client = GetClientOfUserId(event.GetInt("userid"));
        if (IsPlayer(client) && OnActiveTeam(client)) {
            SetEntProp(client, Prop_Send, "m_iAccount", GetCvarIntSafe("mp_maxmoney"));
        }
    }
}

public Action Event_MatchOver(Event event, const char[] name, bool dontBroadcast) {
    if (g_GameState == GameState_Live) {
        MatchTeam winningTeam = g_LastRoundWinner;

        if (winningTeam == MatchTeam_Team1) {
            g_TeamMapScores[MatchTeam_Team1]++;
        } else {
            g_TeamMapScores[MatchTeam_Team2]++;
        }

        float minDelay = FindConVar("tv_delay").FloatValue + MATCH_END_DELAY_AFTER_TV;
        if (g_TeamMapScores[MatchTeam_Team1] == g_MapsToWin) {
            Trate_MessageToAll("%s has won the series.", g_FormattedTeamNames[MatchTeam_Team1]);
            CreateTimer(minDelay, Timer_EndSeries);
        } else if (g_TeamMapScores[MatchTeam_Team2] == g_MapsToWin) {
            Trate_MessageToAll("%s has won the series.", g_FormattedTeamNames[MatchTeam_Team2]);
            CreateTimer(minDelay, Timer_EndSeries);
        } else {
            if (g_TeamMapScores[MatchTeam_Team1] > g_TeamMapScores[MatchTeam_Team2]) {
                Trate_MessageToAll("%s{NORMAL} is winning the series %d-%d",
                    g_FormattedTeamNames[MatchTeam_Team1], g_TeamMapScores[MatchTeam_Team1], g_TeamMapScores[MatchTeam_Team2]);
            } else if (g_TeamMapScores[MatchTeam_Team2] > g_TeamMapScores[MatchTeam_Team1]) {
                Trate_MessageToAll("%s {NORMAL}is winning the series %d-%d",
                    g_FormattedTeamNames[MatchTeam_Team2], g_TeamMapScores[MatchTeam_Team2], g_TeamMapScores[MatchTeam_Team1]);
            } else {
                Trate_MessageToAll("The series is tied at %d-%d", g_TeamMapScores[MatchTeam_Team1], g_TeamMapScores[MatchTeam_Team1]);
            }

            int index = g_TeamMapScores[MatchTeam_Team1] + g_TeamMapScores[MatchTeam_Team2];
            char nextMap[PLATFORM_MAX_PATH];
            g_MapsToPlay.GetString(index, nextMap, sizeof(nextMap));

            g_MapChangePending = true;
            Trate_MessageToAll("The next map in the series is {GREEN}%s", nextMap);
            ChangeState(GameState_PostGame);
            CreateTimer(minDelay, Timer_NextMatchMap);
        }
    }

    return Plugin_Continue;
}

public Action Timer_NextMatchMap(Handle timer) {
    StopRecording();

    int index = g_TeamMapScores[MatchTeam_Team1] + g_TeamMapScores[MatchTeam_Team2];
    char map[PLATFORM_MAX_PATH];
    g_MapsToPlay.GetString(index, map, sizeof(map));
    ChangeMap(map);
}

public Action Timer_EndSeries(Handle timer) {
    ChangeState(GameState_None);
    for (int i = 1; i <= MaxClients; i++) {
        if (IsPlayer(i)) {
            KickClient(i, "The match has been finished");
        }
    }

    StopRecording();
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    int winner = event.GetInt("winner");
    g_LastRoundWinner = CSTeamToMatchTeam(winner);

    if (g_GameState == GameState_KnifeRound) {
        ChangeState(GameState_WaitingForKnifeRoundDecision);

        int ctAlive = CountAlivePlayersOnTeam(CS_TEAM_CT);
        int tAlive = CountAlivePlayersOnTeam(CS_TEAM_T);
        int winningCSTeam = CS_TEAM_NONE;
        if (ctAlive > tAlive) {
            winningCSTeam = CS_TEAM_CT;
        } else if (tAlive > ctAlive) {
            winningCSTeam = CS_TEAM_T;
        } else {
            int ctHealth = SumHealthOfTeam(CS_TEAM_CT);
            int tHealth = SumHealthOfTeam(CS_TEAM_T);
            if (ctHealth > tHealth) {
                winningCSTeam = CS_TEAM_CT;
            } else if (tHealth > ctHealth) {
                winningCSTeam = CS_TEAM_T;
            } else {
                if (GetRandomFloat(0.0, 1.0) < 0.5) {
                    winningCSTeam = CS_TEAM_CT;
                } else {
                    winningCSTeam = CS_TEAM_T;
                }
            }
        }

        g_KnifeWinnerTeam = CSTeamToMatchTeam(winningCSTeam);
        Trate_MessageToAll("%s won the knife round. Waiting for them to type !stay or !swap.",
            g_FormattedTeamNames[g_KnifeWinnerTeam]);
    }
}

public Action Event_PhaseEnd(Event event, const char[] name, bool dontBroadcast) {
    LogDebug("Event_PhaseEnd, g_GameState = %d, gamephase = %d", g_GameState, GetGamePhase());
    // TODO: this team score equality doesn't work if there are even-number halves
    if (InHalftimePhase() && CS_GetTeamScore(CS_TEAM_T) != CS_GetTeamScore(CS_TEAM_CT)) {
        int tmp = g_TeamSide[MatchTeam_Team1];
        g_TeamSide[MatchTeam_Team1] = g_TeamSide[MatchTeam_Team2];
        g_TeamSide[MatchTeam_Team2] = tmp;
    }
}

/**
 * Silences cvar changes when executing live/knife/warmup configs, *unless* it's sv_cheats.
 */
public Action Event_CvarChanged(Event event, const char[] name, bool dontBroadcast) {
    if (g_GameState != GameState_None) {
        char cvarName[MAX_CVAR_LENGTH];
        event.GetString("cvarname", cvarName, sizeof(cvarName));
        if (!StrEqual(cvarName, "sv_cheats")) {
            event.BroadcastDisabled = true;
        }
    }

    return Plugin_Continue;
}

public void StartGame() {
    if (!IsTVEnabled()) {
        LogError("GOTV demo could not be recorded since tv_enable is not set to 1");
    } else {
        // get the map, with any workshop stuff before removed
        // this is {MAP} in the format string
        char mapName[PLATFORM_MAX_PATH];
        GetCleanMapName(mapName, sizeof(mapName));

        // get the time, this is {TIME} in the format string
        char timeFormat[64];
        g_DemoTimeFormatCvar.GetString(timeFormat, sizeof(timeFormat));
        int timeStamp = GetTime();
        char formattedTime[64];
        FormatTime(formattedTime, sizeof(formattedTime), timeFormat, timeStamp);

        // get the player count, this is {TEAMSIZE} in the format string
        char playerCount[MAX_INTEGER_STRING_LENGTH];
        IntToString(g_PlayersPerTeam, playerCount, sizeof(playerCount));

        // create the actual demo name to use
        char demoName[PLATFORM_MAX_PATH];
        g_DemoNameFormatCvar.GetString(demoName, sizeof(demoName));

        int mapNumber = g_TeamMapScores[MatchTeam_Team1] + g_TeamMapScores[MatchTeam_Team2] + 1;
        ReplaceStringWithInt(demoName, sizeof(demoName), "{MAPNUMBER}", mapNumber, false);
        ReplaceString(demoName, sizeof(demoName), "{MATCHID}", g_MatchID, false);
        ReplaceString(demoName, sizeof(demoName), "{MAPNAME}", mapName, false);
        ReplaceString(demoName, sizeof(demoName), "{TIME}", formattedTime, false);
        ReplaceString(demoName, sizeof(demoName), "{TEAM1}", g_TeamNames[MatchTeam_Team1], false);
        ReplaceString(demoName, sizeof(demoName), "{TEAM2}", g_TeamNames[MatchTeam_Team2], false);

        if (Record(demoName)) {
            LogMessage("Recording to %s", demoName);
            Format(g_DemoFileName, sizeof(g_DemoFileName), "%s.dem", demoName);
        }
    }

    ServerCommand("exec %s", LIVE_CONFIG);
    ServerCommand("exec %s", KNIFE_CONFIG);
    EndWarmup();
    CreateTimer(3.0, StartKnifeRound);
}

public Action StopDemo(Handle timer) {
    StopRecording();
    return Plugin_Handled;
}

public void ChangeState(GameState state) {
    LogDebug("Change from state %d -> %d", g_GameState, state);
    g_GameState = state;
}

public Action Command_Status(int client, int args) {
    ReplyToCommand(client, "{");
    ReplyToCommand(client, "  \"matchid\": \"%s\",", g_MatchID);
    ReplyToCommand(client, "  \"plugin_version\": \"%s\",", PLUGIN_VERSION);

    #if defined COMMIT_STRING
    ReplyToCommand(client, "  \"commit: \"%s\"\"", COMMIT_STRING);
    #endif

    char gamestate[64];
    GameStateString(g_GameState, gamestate, sizeof(gamestate));
    ReplyToCommand(client, "  \"gamestate\": \"%s\",", gamestate);

    if (g_GameState != GameState_None) {
        ReplyToCommand(client, "  \"loaded_config_file\": \"%s\",", g_LoadedConfigFile);
        ReplyToCommand(client, "  \"map_number\": %d,",
            g_TeamMapScores[MatchTeam_Team1] + g_TeamMapScores[MatchTeam_Team2] + 1);

        ReplyToCommand(client, "  \"team1\": {");
        ReplyToTeamInfo(client, MatchTeam_Team1);
        ReplyToCommand(client, "  },");

        ReplyToCommand(client, "  \"team2\": {");
        ReplyToTeamInfo(client, MatchTeam_Team2);

        if (g_GameState > GameState_Veto)
            ReplyToCommand(client, "  },");
        else
            ReplyToCommand(client, "  }");
    }

    if (g_GameState > GameState_Veto) {
        ReplyToCommand(client, "  \"maps\": {");
        for (int i = 0; i < g_MapsToPlay.Length; i++) {
            char mapName[PLATFORM_MAX_PATH];
            g_MapsToPlay.GetString(i, mapName, sizeof(mapName));
            if (i + 1 < g_MapsToPlay.Length)
                ReplyToCommand(client, "    \"map%d\" : \"%s\",", i + 1, mapName);
            else // No commma on the last map.
                ReplyToCommand(client, "    \"map%d\" : \"%s\"", i + 1, mapName);
        }
        ReplyToCommand(client, "  }");
    }

    ReplyToCommand(client, "}");
    return Plugin_Handled;
}

static void ReplyToTeamInfo(int client, MatchTeam matchTeam) {
    int team = MatchTeamToCSTeam(matchTeam);
    char side[4];
    CSTeamString(team, side, sizeof(side));
    ReplyToCommand(client, "    \"name\": \"%s\",", g_TeamNames[matchTeam]);
    ReplyToCommand(client, "    \"map_score\": %d,", g_TeamMapScores[matchTeam]);
    ReplyToCommand(client, "    \"ready\": %d,", g_TeamReady[matchTeam]);
    ReplyToCommand(client, "    \"side\": \"%s\",", side);
    ReplyToCommand(client, "    \"connected_clients\": %d,", GetNumHumansOnTeam(team));
    ReplyToCommand(client, "    \"current_score\": %d", CS_GetTeamScore(team));
}

public bool AllTeamsReady() {
    return g_TeamReady[MatchTeam_Team1] && g_TeamReady[MatchTeam_Team2];
}
