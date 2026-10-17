// Drives a Pastemind started with PASTEMIND_DEBUG=1 (see Sources/PastemindApp/DebugHooks.swift), and writes to its private pasteboard.
//   pastemindctl show | hide | query <text> | down [n] | up [n] | paste [plain] | snapshot <path> | dump [n]
//   pastemindctl type <text>                            types it into the clipboard field, logs the main thread's busy stretches
//   pastemindctl stype <text> | measure <seconds> [label]  typing into search; the main thread's busy stretches meanwhile
//   pastemindctl look | lookfilm <folder>               Quick Look for the selected clip, as a tap of ⇧ would; filmed (48 frames)
//   pastemindctl lookagain <ms>                         Quick Look toggled twice that far apart, its windows logged
//   pastemindctl tab | snip-new | snip-save               ⇥ (snippets and back), ⌘N, ⌘S in the clipboard history
//   pastemindctl snip-folder | snip-move <folder>|- | snip-dump   ⇧⌘N; the selected snippet moved; the list logged
//   pastemindctl selectpreview "<start> <length>" | copysel   selects some of the preview's text; ⌘C on it
//   pastemindctl clear 5m|15m|today|all                 clears a range at once (Settings has it)
//   pastemindctl pointer "<x> <y>"|off | click "<x> <y> [count]"   the pointer over the clipboard list, or a click on it
//                                                      (points in the window from its top left)
//   pastemindctl search | squery <text> | sdown [n] | stab | slook | sdump [n] | ssnapshot <path>     the search panel
//   pastemindctl hotkey clipboard|search                as if that hotkey was pressed
//   pastemindctl switch clipboard|search                the same, logging the main thread's busy stretches for a second
//   pastemindctl menubar on|off | reopen                 the menu bar icon (unsaved), opening the app again
//   pastemindctl film <folder>                           30 frames of the panels, 16 ms apart, with their heights
//   pastemindctl settings | settingssnapshot <path> | settingsdump   Settings; its frames logged
//   pastemindctl settingsscroll <points>              Settings scrolled that far down
//   pastemindctl welcome | welcomeclose | welcomesnapshot <path>   the welcome window a new install opens with
//   pastemindctl welcomestate start|done|failed          the welcome as it'd look then (till the app quits)
//   pastemindctl welcomepage 0|1|2                       one of its pages, as Next and Back show them
//   pastemindctl qlstate | qlkey                        Quick Look's state logged; it taking the key, as a click in it does
//   pastemindctl qlviews | qledit [all]                 Quick Look's views logged; its Edit menu checked as a click in it leaves it (then Select All)
//   pastemindctl dropped                                as if the selected clip (or snippet) was dragged into an app
//   pastemindctl dragpb                                 what dragging the selected clip out carries, logged
//   pastemindctl options-pointer on|off|auto              the pointer taken as over the panels (the options button shows)
//   pastemindctl options [seconds]                       the clipboard panel's options menu, up for that long (2 s)
//   pastemindctl settingsnote <text>                    a note under Clear history for 2.5 s (its height changing)
//   pastemindctl shadow <path> | sshadow <path>      a panel with its shadow
//   pastemindctl glassonly on|off                     the panels' content hidden, their glass alone
//   pastemindctl spin on|off                          both panels' spinners up, or not
//   pastemindctl copy <text>              puts text on the pasteboard named by $PASTEMIND_PASTEBOARD (default app.pastemind.test)
//   pastemindctl copy-image <path>        puts a PNG there
//   pastemindctl copy-files <path>…       puts file URLs there
//   pastemindctl preview-snapshot <png>   the selected clip's preview pane, drawn off screen (the panel stays hidden)
//   pastemindctl read                     prints what's there (types, and the text)
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("usage: pastemindctl <command> [argument]")
    exit(2)
}
let rest = arguments.dropFirst().joined(separator: " ")
let board = NSPasteboard(name: NSPasteboard.Name(ProcessInfo.processInfo.environment["PASTEMIND_PASTEBOARD"] ?? "app.pastemind.test"))
switch command {
case "copy":
    board.clearContents()
    board.setString(rest, forType: .string)
case "copy-image":
    board.clearContents()
    board.setData(try! Data(contentsOf: URL(fileURLWithPath: rest)), forType: .png)
case "copy-files":
    board.clearContents()
    board.writeObjects(arguments.dropFirst().map { URL(fileURLWithPath: $0) as NSURL })
case "read":
    print("types:", (board.types ?? []).map(\.rawValue).joined(separator: ", "))
    print(board.string(forType: .string) ?? "(no text)")
default:
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.pastemind.debug"), object: command,
                                                                 userInfo: ["argument": rest], deliverImmediately: true)
}
