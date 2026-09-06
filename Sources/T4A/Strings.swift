//  Strings.swift — every word T4A owns will end up here.
//
//  This first slice is intentionally small: it proves that one catalog can
//  serve drawn text, AppKit controls, and text assembled from live values.
//  English is the source beside each Italian translation, so either language
//  can be read straight through and prose that only makes sense as a
//  translation has nowhere to hide. Developer logs, identifiers, paths, and
//  diagnostic artifacts are not UI and do not belong in this file.

import TerminalCore

enum S {
    // MARK: - Language settings

    static var settingsWindowTitle: String {
        L.t(en: "T4A Settings", it: "Impostazioni T4A")
    }

    static var language: String {
        L.t(en: "Language", it: "Lingua")
    }

    static var languageNote: String {
        L.t(
            en: "changes every open window without a restart",
            it: "cambia ogni finestra aperta senza riavviare"
        )
    }

    static var languageSystem: String {
        L.t(en: "follow the system", it: "segui il sistema")
    }

    static var languageEnglish: String {
        L.t(en: "English", it: "inglese")
    }

    static var languageItalian: String {
        L.t(en: "Italian", it: "italiano")
    }

    // MARK: - Main menu

    static var aboutT4A: String {
        L.t(en: "About T4A", it: "Informazioni su T4A")
    }

    static var openConfigurationFile: String {
        L.t(en: "Open configuration file", it: "Apri il file di configurazione")
    }

    static var hideT4A: String {
        L.t(en: "Hide T4A", it: "Nascondi T4A")
    }

    static var hideOthers: String {
        L.t(en: "Hide Others", it: "Nascondi le altre")
    }

    static var quitT4A: String {
        L.t(en: "Quit T4A", it: "Esci da T4A")
    }

    static var shellMenu: String {
        L.t(en: "Shell", it: "Terminale")
    }

    static var newWindow: String {
        L.t(en: "New Window", it: "Nuova finestra")
    }

    static var goToSession: String {
        L.t(en: "Go to Session", it: "Vai alla sessione")
    }

    static func session(number: Int) -> String {
        L.t(en: "Session \(number)", it: "Sessione \(number)")
    }

    static var newTab: String {
        L.t(en: "New Tab", it: "Nuova scheda")
    }

    static var splitRight: String {
        L.t(en: "Split Right", it: "Dividi a destra")
    }

    static var splitDown: String {
        L.t(en: "Split Down", it: "Dividi in basso")
    }

    static var closePane: String {
        L.t(en: "Close Pane", it: "Chiudi riquadro")
    }

    static var editMenu: String {
        L.t(en: "Edit", it: "Modifica")
    }

    static var undo: String {
        L.t(en: "Undo", it: "Annulla")
    }

    static var redo: String {
        L.t(en: "Redo", it: "Ripeti")
    }

    static var copy: String {
        L.t(en: "Copy", it: "Copia")
    }

    static var paste: String {
        L.t(en: "Paste", it: "Incolla")
    }

    static var selectAll: String {
        L.t(en: "Select All", it: "Seleziona tutto")
    }

    static var messageThisSession: String {
        L.t(en: "Message This Session", it: "Scrivi a questa sessione")
    }

    static var find: String {
        L.t(en: "Find…", it: "Trova…")
    }

    static var findNext: String {
        L.t(en: "Find Next", it: "Trova successivo")
    }

    static var findPrevious: String {
        L.t(en: "Find Previous", it: "Trova precedente")
    }

    static var viewMenu: String {
        L.t(en: "View", it: "Vista")
    }

    static var bigger: String {
        L.t(en: "Bigger", it: "Aumenta")
    }

    static var smaller: String {
        L.t(en: "Smaller", it: "Riduci")
    }

    static var actualSize: String {
        L.t(en: "Actual Size", it: "Dimensioni reali")
    }

    static var commandPalette: String {
        L.t(en: "Command Palette", it: "Palette dei comandi")
    }

    static var clearBuffer: String {
        L.t(en: "Clear Buffer", it: "Svuota buffer")
    }

    static var chatPage: String {
        L.t(en: "Chat Page", it: "Pagina chat")
    }

    static var commandMap: String {
        L.t(en: "Command Map", it: "Mappa comandi")
    }

    static var dashboard: String {
        L.t(en: "Dashboard", it: "Cruscotto")
    }

    static var preview: String {
        L.t(en: "Preview", it: "Anteprima")
    }

    static var previewInFront: String {
        L.t(en: "Preview in Front", it: "Porta l'anteprima davanti")
    }

    static var sessionsAsTabsOrRail: String {
        L.t(en: "Sessions as Tabs / Rail", it: "Sessioni in schede / barra laterale")
    }

    static var nextTheme: String {
        L.t(en: "Next Theme", it: "Tema successivo")
    }

    static var dumpLayout: String {
        L.t(en: "Dump Layout", it: "Esporta disposizione")
    }

    static var windowMenu: String {
        L.t(en: "Window", it: "Finestra")
    }

    static var minimize: String {
        L.t(en: "Minimize", it: "Contrai")
    }

    static var zoom: String {
        L.t(en: "Zoom", it: "Ridimensiona")
    }

    static var bringAllToFront: String {
        L.t(en: "Bring All to Front", it: "Porta tutto in primo piano")
    }

    static var aboutCredits: String {
        L.t(
            en: "A terminal that treats agent sessions as objects.\nOpen source, MIT.",
            it: "Un terminale che tratta le sessioni degli agenti come oggetti.\nOpen source, MIT."
        )
    }

    // MARK: - SettingsWindow

    static var settingsCategorySessions: String {
        L.t(en: "Sessions", it: "Sessioni")
    }

    static var settingsCategoryLayout: String {
        L.t(en: "Layout", it: "Disposizione")
    }

    static var settingsCategoryAppearance: String {
        L.t(en: "Appearance", it: "Aspetto")
    }

    static var settingsCategoryDashboardRows: String {
        L.t(en: "Dashboard rows", it: "Righe del cruscotto")
    }

    static var settingsCategoryTerminal: String {
        L.t(en: "Terminal", it: "Terminale")
    }

    static var settingsWhereTheyLive: String {
        L.t(en: "Where they live", it: "Dove si trovano")
    }

    static var settingsSideRail: String {
        L.t(en: "side rail", it: "barra laterale")
    }

    static var settingsTabsOnTop: String {
        L.t(en: "tabs on top", it: "schede in alto")
    }

    static var settingsOneTab: String {
        L.t(en: "One tab", it: "Una scheda")
    }

    static var settingsOneTabNote: String {
        L.t(
            en: "with a single tab, the bar can wait for the second",
            it: "con una sola scheda, mostra la barra solo dalla seconda"
        )
    }

    static var settingsShowTheBar: String {
        L.t(en: "show the bar", it: "mostra la barra")
    }

    static var settingsHideUntilSecond: String {
        L.t(en: "hide until a second", it: "nascondi fino alla seconda")
    }

    static var settingsInput: String {
        L.t(en: "Input", it: "Inserimento")
    }

    static var settingsInputNote: String {
        L.t(en: "where what you type is written", it: "dove viene scritto ciò che digiti")
    }

    static var settingsT4ABubble: String {
        L.t(en: "the T4A bubble", it: "la bolla di T4A")
    }

    static var settingsAgentLine: String {
        L.t(en: "the agent's own line", it: "la riga dell'agente")
    }

    static var settingsSessionsPanel: String {
        L.t(en: "Sessions panel", it: "Pannello sessioni")
    }

    static var settingsSessionsPanelNote: String {
        L.t(en: "the rail down the left side", it: "la barra lungo il lato sinistro")
    }

    static var settingsTurnMap: String {
        L.t(en: "Turn map", it: "Mappa dei turni")
    }

    static var settingsTurnMapNote: String {
        L.t(en: "the panel down the right side", it: "il pannello lungo il lato destro")
    }

    static var settingsDashboardBar: String {
        L.t(en: "Dashboard bar", it: "Barra del cruscotto")
    }

    static var settingsDashboardBarNote: String {
        L.t(en: "the strip along the bottom", it: "la striscia lungo il bordo inferiore")
    }

    static var settingsComposer: String {
        L.t(en: "Composer", it: "Scrittura")
    }

    static var settingsComposerNote: String {
        L.t(
            en: "the line that types into the selected session",
            it: "la riga che scrive nella sessione selezionata"
        )
    }

    static var settingsWithAgent: String {
        L.t(en: "with an agent", it: "con un agente")
    }

    static var settingsWhenNeeded: String {
        L.t(en: "when it is needed", it: "quando serve")
    }

    static var settingsAlways: String {
        L.t(en: "always", it: "sempre")
    }

    static var settingsNever: String {
        L.t(en: "never", it: "mai")
    }

    static var settingsChatPage: String {
        L.t(en: "Chat page", it: "Pagina chat")
    }

    static var settingsChatPageNote: String {
        L.t(
            en: "draw the conversation here instead of the agent's own screen: the work folds into one line per block, the answer stays whole",
            it: "mostra qui la conversazione invece della schermata dell'agente: il lavoro si ripiega in una riga per blocco, la risposta resta intera"
        )
    }

    static var settingsPureChat: String {
        L.t(en: "Pure chat", it: "Chat pura")
    }

    static var settingsPureChatNote: String {
        L.t(
            en: "experimental: cover the agent's own prompt while it rests, and uncover it the moment it asks you something",
            it: "sperimentale: copre il prompt dell'agente mentre è fermo e lo scopre appena ti chiede qualcosa"
        )
    }

    static var settingsTheme: String {
        L.t(en: "Theme", it: "Tema")
    }

    static var settingsThemeNote: String {
        L.t(
            en: "yours go in themes/ beside the configuration file",
            it: "i tuoi vanno in themes/ accanto al file di configurazione"
        )
    }

    static func settingsThemeFallback(current: String, problem: String) -> String {
        L.t(
            en: "using \(current) instead — \(problem)",
            it: "uso \(current) al suo posto — \(problem)"
        )
    }

    static func settingsThemeTitle(name: String, fallback: String) -> String {
        switch name {
        case "black": return L.t(en: "full black", it: "nero pieno")
        case "warm": return L.t(en: "warm dark", it: "scuro caldo")
        case "violet": return L.t(en: "violet dark", it: "viola scuro")
        case "light": return L.t(en: "light", it: "chiaro")
        case "paper": return L.t(en: "warm paper", it: "carta calda")
        default: return fallback
        }
    }

    static var settingsMotion: String {
        L.t(en: "Motion", it: "Animazioni")
    }

    static var settingsMotionNote: String {
        L.t(en: "when off, nothing in the window animates", it: "se disattivate, nulla nella finestra si anima")
    }

    static var settingsShellIntegration: String {
        L.t(en: "Shell integration", it: "Integrazione shell")
    }

    static var settingsShellIntegrationNote: String {
        L.t(en: "command blocks, read from OSC 133", it: "blocchi di comandi, letti da OSC 133")
    }

    static var settingsAgentAdapter: String {
        L.t(en: "Agent adapter", it: "Adattatore agente")
    }

    static var settingsAgentAdapterNote: String {
        L.t(en: "off and this is an ordinary terminal", it: "se disattivato, questo è un normale terminale")
    }

    static var settingsCompactTurns: String {
        L.t(en: "Compact turns", it: "Turni compatti")
    }

    static var settingsCompactTurnsNote: String {
        L.t(en: "a turn's work folded away by default", it: "il lavoro di un turno è ripiegato per impostazione predefinita")
    }

    static var settingsNotifications: String {
        L.t(en: "Notifications", it: "Notifiche")
    }

    static var settingsNotificationsNote: String {
        L.t(en: "when a session you are not watching waits", it: "quando una sessione che non stai guardando resta in attesa")
    }

    static var settingsCopyOnSelect: String {
        L.t(en: "Copy on select", it: "Copia quando selezioni")
    }

    static var settingsCopyOnSelectNote: String {
        L.t(
            en: "selecting with the mouse puts the text on the clipboard",
            it: "selezionare con il mouse mette il testo negli appunti"
        )
    }

    static var settingsReorderDashboardRows: String {
        L.t(
            en: "drag by the handle to reorder within a line of the bar",
            it: "trascina la maniglia per riordinare le voci in una riga della barra"
        )
    }

    static var settingsRunningWork: String {
        L.t(en: "Running work", it: "Lavoro in corso")
    }

    static var settingsRunningWorkNote: String {
        L.t(
            en: "the transient WORKER cell while something runs",
            it: "la cella temporanea WORKER mentre qualcosa è in esecuzione"
        )
    }

    // MARK: - MainWindowController

    static var splitRightTooltip: String {
        L.t(en: "split right (⌘D)", it: "dividi a destra (⌘D)")
    }

    enum CloseSubject {
        case pane, tab, window
    }

    static func closeQuestion(subject: CloseSubject) -> String {
        switch subject {
        case .pane: return L.t(en: "Close this pane?", it: "Chiudere questo riquadro?")
        case .tab: return L.t(en: "Close this tab?", it: "Chiudere questa scheda?")
        case .window: return L.t(en: "Close this window?", it: "Chiudere questa finestra?")
        }
    }

    static func closeRunningProcesses(names: String, count: Int) -> String {
        if count == 1 {
            return L.t(
                en: "\(names) is still running here. Closing kills it.",
                it: "\(names) è ancora in esecuzione qui. La chiusura lo termina."
            )
        }
        return L.t(
            en: "\(names) are still running here. Closing kills them.",
            it: "\(names) sono ancora in esecuzione qui. La chiusura li termina."
        )
    }

    static var closeAnyway: String {
        L.t(en: "Close anyway", it: "Chiudi comunque")
    }

    static var cancel: String {
        L.t(en: "Cancel", it: "Annulla")
    }

    static var yes: String {
        L.t(en: "Yes", it: "Sì")
    }

    static var no: String {
        L.t(en: "No", it: "No")
    }

    static var stagedQuestion: String {
        L.t(en: "A question nobody asked", it: "Una domanda che nessuno ha posto")
    }

    static var stagedDetail: String {
        L.t(en: "staged by the bench", it: "inserita dal test")
    }

    static var stagedKind: String {
        L.t(en: "staged", it: "test")
    }

    // MARK: - AgentViews

    static var approve: String {
        L.t(en: "Approve", it: "Approva")
    }

    static var deny: String {
        L.t(en: "Deny", it: "Nega")
    }

    static var nothingWasSent: String {
        L.t(en: "Nothing was sent", it: "Non è stato inviato nulla")
    }

    static var withdrawn: String {
        L.t(en: "WITHDRAWN", it: "RITIRATA")
    }

    static var messageThisSessionPlaceholder: String {
        L.t(en: "message this session…", it: "scrivi a questa sessione…")
    }

    // MARK: - Chrome

    static var turnMapPanel: String {
        L.t(en: "turn map panel", it: "pannello della mappa dei turni")
    }

    static var previewPanel: String {
        L.t(en: "preview panel", it: "pannello di anteprima")
    }

    static var dashboardBar: String {
        L.t(en: "dashboard bar", it: "barra del cruscotto")
    }

    static var sessionsLayout: String {
        L.t(en: "sessions layout", it: "disposizione delle sessioni")
    }

    static var settingsButton: String {
        L.t(en: "settings", it: "impostazioni")
    }

    static var waiting: String {
        L.t(en: "waiting", it: "in attesa")
    }

    static var moveSessionsLeft: String {
        L.t(en: "move the sessions down the left side", it: "sposta le sessioni lungo il lato sinistro")
    }

    static var moveSessionsTop: String {
        L.t(en: "move the sessions up to the top", it: "sposta le sessioni in alto")
    }

    // MARK: - CommandPalette

    static var commandPalettePlaceholder: String {
        L.t(en: "sessions, themes, actions", it: "sessioni, temi, azioni")
    }

    static var commandPaletteNoMatches: String {
        L.t(en: "nothing by that name", it: "nessun risultato con quel nome")
    }

    static var commandPaletteSessions: String {
        L.t(en: "sessions", it: "sessioni")
    }

    static var commandPaletteThemes: String {
        L.t(en: "themes", it: "temi")
    }

    static var commandPaletteActions: String {
        L.t(en: "actions", it: "azioni")
    }

    static var commandPaletteWaitingForYou: String {
        L.t(en: "waiting for you", it: "aspetta te")
    }

    static var commandPaletteCurrent: String {
        L.t(en: "current", it: "in uso")
    }

    static var commandPaletteYours: String {
        L.t(en: "yours", it: "tuo")
    }

    static var settingsEllipsis: String {
        L.t(en: "Settings…", it: "Impostazioni…")
    }

    static var dashboardBarAction: String {
        L.t(en: "Dashboard Bar", it: "Barra del cruscotto")
    }

    // MARK: - QueuedView

    static func queuedPrefix(count: Int) -> String {
        let suffix = count > 1 ? " (\(count))" : ""
        return L.t(en: "queued\(suffix) · ", it: "in coda\(suffix) · ")
    }

    // MARK: - TurnProse

    static var turnWithoutQuestion: String {
        L.t(
            en: "(nothing: this turn has no question)",
            it: "(niente: questo turno non porta una domanda)"
        )
    }

    static func turnNumber(id: Int) -> String {
        L.t(en: "turn \(id)", it: "turno \(id)")
    }

    static var turnFailed: String {
        L.t(en: " · failed", it: " · fallito")
    }

    static var turnYouAsked: String {
        L.t(en: "YOU ASKED", it: "GLI HAI CHIESTO")
    }

    static var turnAnswer: String {
        L.t(en: "THE ANSWER", it: "LA RISPOSTA")
    }

    static func turnCommandCount(_ count: Int) -> String {
        L.t(
            en: count == 1 ? "1 command" : "\(count) commands",
            it: count == 1 ? "1 comando" : "\(count) comandi"
        )
    }

    static func turnWorkSummary(commandCount: Int, isOpen: Bool) -> String {
        let count = turnCommandCount(commandCount)
        return L.t(
            en: isOpen ? "Running · \(count)" : "Ran \(count)",
            it: isOpen ? "In esecuzione · \(count)" : "Eseguiti \(count)"
        )
    }

    static var turnNoAnswerWritten: String {
        L.t(en: "(no answer written)", it: "(nessuna risposta scritta)")
    }

    static func turnAfterStopHook(source: String) -> String {
        L.t(en: "↳ after Stop hook\(source)", it: "↳ dopo lo Stop hook\(source)")
    }

    // MARK: - PreviewSurface

    static var fileNoLongerOnDisk: String {
        L.t(en: " is no longer on disk.", it: " non è più sul disco.")
    }

    // MARK: - FindBar

    static var findInChat: String {
        L.t(en: "in the chat", it: "nella chat")
    }

    static var findOnScreen: String {
        L.t(en: "on screen", it: "sullo schermo")
    }

    static func noFindResults(source: String) -> String {
        L.t(en: "none \(source)", it: "nessun risultato \(source)")
    }

    static var findPlaceholder: String {
        L.t(en: "find", it: "trova")
    }

    static var findRegexTooltip: String {
        L.t(
            en: "treat what you type as a regular expression",
            it: "interpreta ciò che digiti come espressione regolare"
        )
    }

    static func findTurnPrefix(id: Int) -> String {
        L.t(en: "turn \(id) · ", it: "turno \(id) · ")
    }

    // MARK: - RailView

    static var sessionsHeading: String {
        L.t(en: "SESSIONS", it: "SESSIONI")
    }

    static var sessionWorking: String {
        L.t(en: "working", it: "al lavoro")
    }

    static var sessionWaitsForYou: String {
        L.t(en: "waits for you", it: "aspetta te")
    }

    static var sessionWaiting: String {
        L.t(en: "waiting", it: "in attesa")
    }

    static var sessionIdle: String {
        L.t(en: "idle", it: "inattiva")
    }

    static func sessionTurnCount(_ count: Int) -> String {
        L.t(
            en: count == 1 ? "1 turn" : "\(count) turns",
            it: count == 1 ? "1 turno" : "\(count) turni"
        )
    }

    // MARK: - DashRows

    static var emptyDashboardLine: String {
        L.t(en: "empty — drop a row here", it: "vuota — trascina qui una voce")
    }

    // MARK: - TurnReaderView

    static var turnReaderCloseHint: String {
        L.t(en: "esc to close", it: "esc per chiudere")
    }

    // MARK: - MainWindowController composer

    static var agentInputOffScreen: String {
        L.t(
            en: "the agent's input line is not on screen: look at the terminal (⌥⌘C)",
            it: "la riga d'ingresso dell'agente non è sullo schermo: guarda il terminale (⌥⌘C)"
        )
    }

    // MARK: - Updates (ISC-248)

    static var updates: String {
        L.t(en: "Updates", it: "Aggiornamenti")
    }

    static var updatesNote: String {
        L.t(
            en: "asks GitHub only when you press the button",
            it: "chiede a GitHub solo quando premi il tasto"
        )
    }

    static var checkForUpdates: String {
        L.t(en: "Check for updates", it: "Cerca aggiornamenti")
    }

    static var updateChecking: String {
        L.t(en: "checking…", it: "controllo…")
    }

    static func updateUpToDate(current: String) -> String {
        L.t(en: "\(current) is the latest", it: "\(current) è l'ultima")
    }

    static func updateAvailable(version: String) -> String {
        L.t(en: "\(version) is available", it: "c'è la \(version)")
    }

    static func installUpdate(version: String) -> String {
        L.t(en: "Install \(version)", it: "Installa \(version)")
    }

    static var openReleasePage: String {
        L.t(en: "Open the release page", it: "Apri la pagina della release")
    }

    static var updateInstalling: String {
        L.t(en: "installing…", it: "installo…")
    }

    // MARK: - InspectorView (heading and the empty command)

    static var inspectorTurns: String {
        L.t(en: "turns", it: "turni")
    }

    static var inspectorCommandMap: String {
        L.t(en: "command map", it: "mappa dei comandi")
    }

    static var inspectorPromptBlock: String {
        L.t(en: "(prompt)", it: "(prompt)")
    }

    // MARK: - Composed summaries (fold strip, inspector rows)

    static func linesFolded(count: Int) -> String {
        L.t(en: "\(count) lines folded", it: "\(count) righe ripiegate")
    }

    static func lines(count: Int) -> String {
        L.t(en: "\(count) lines", it: "\(count) righe")
    }

    static func tools(count: Int) -> String {
        L.t(en: "\(count) tool\(count == 1 ? "" : "s")",
            it: "\(count) strument\(count == 1 ? "o" : "i")")
    }

    static var noTools: String {
        L.t(en: "no tools", it: "nessuno strumento")
    }

    static func failed(count: Int) -> String {
        L.t(en: "\(count) failed", it: "\(count) fallit\(count == 1 ? "o" : "i")")
    }
}
