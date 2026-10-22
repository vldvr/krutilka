import AppKit
import AVFoundation

/// Headless runs for testing the engines without the wheel:
///   Krutilka --op convert list <files…>      lists segment ids
///   Krutilka --op convert png <files…>       runs one and prints the results
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--op") }

    @MainActor static func run() {
        // Without windows AppKit may consider the process idle and end it while a job awaits a helper.
        ProcessInfo.processInfo.disableAutomaticTermination("self test")
        ProcessInfo.processInfo.disableSuddenTermination()
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--op"), args.count > i + 3,
              let wheel = WheelKind(rawValue: args[i + 1]) else {
            print("usage: Krutilka --op convert|tools|actions <id|list> <files…>")
            exit(64)
        }
        let id = args[i + 2]
        let files = args[(i + 3)...].filter { $0 != "--job" }.map { URL(fileURLWithPath: $0) }
        if id.hasPrefix("trim:") {
            // trim:<start>:<end> in seconds, the cut the trim window would make.
            let parts = id.split(separator: ":").compactMap { Double($0) }
            let range = CMTimeRange(start: CMTime(seconds: parts[0], preferredTimescale: 600),
                                    end: CMTime(seconds: parts[1], preferredTimescale: 600))
            let settings = JobSettings.snapshot()
            Task {
                let ctx = JobContext(inputs: files, settings: settings) { _ in }
                do { print("OK -> \(try await Trimmer.cut(files[0], range: range, ctx: ctx).path)"); exit(0) }
                catch { print("FAIL \(error)"); exit(1) }
            }
            return
        }
        if id.hasPrefix("split:") {
            // split:<t1>,<t2>… marks, like the split window's.
            let marks = id.dropFirst(6).split(separator: ",").compactMap { Double($0) }
            let settings = JobSettings.snapshot()
            Task {
                let ctx = JobContext(inputs: files, settings: settings) { _ in }
                guard let duration = await Media.duration(files[0]) else { print("FAIL no duration"); exit(1) }
                let points = [0] + marks + [duration]
                for (i, pair) in zip(points, points.dropFirst()).enumerated() {
                    let range = CMTimeRange(start: CMTime(seconds: pair.0, preferredTimescale: 600), end: CMTime(seconds: pair.1, preferredTimescale: 600))
                    do { print("OK -> \(try await Trimmer.cut(files[0], range: range, ctx: ctx, suffix: trf("part %d", i + 1)).lastPathComponent)") }
                    catch { print("FAIL \(error)"); exit(1) }
                }
                exit(0)
            }
            return
        }
        if id == "edit-test" {
            // Same path as the editor's Save Copy: one pixelated patch, one black patch, a crop.
            Task {
                do {
                    let image = try await ImageEngine.load(files[0])
                    let model = PhotoEditModel(url: files[0], image: image)
                    let w = CGFloat(image.width), h = CGFloat(image.height)
                    model.hideStyle = .pixelate
                    model.commitRect(CGRect(x: w * 0.1, y: h * 0.1, width: w * 0.3, height: h * 0.2))
                    model.hideStyle = .black
                    model.commitRect(CGRect(x: w * 0.5, y: h * 0.5, width: w * 0.2, height: h * 0.2))
                    model.ink = .red
                    model.commitArrow(from: CGPoint(x: w * 0.1, y: h * 0.7), to: CGPoint(x: w * 0.35, y: h * 0.45))
                    model.typingAt = CGPoint(x: w * 0.05, y: h * 0.72)
                    model.commitNote("Тут")
                    model.mode = .crop
                    model.commitRect(CGRect(x: 0, y: 0, width: w * 0.8, height: h * 0.8))
                    print("OK -> \(try model.save().path)")
                    exit(0)
                } catch { print("FAIL \(error)"); exit(1) }
            }
            return
        }
        let ops = Catalog.operations(for: files, wheel: wheel)
        if id == "list" {
            for op in ops { print("\(op.id)\t\(op.title)\(op.enabled ? "" : "\t(disabled: \(op.disabledReason ?? ""))")") }
            exit(0)
        }
        guard let op = ops.first(where: { $0.id == id }) else {
            print("no segment '\(id)' for these files; have: \(ops.map(\.id).joined(separator: " "))")
            exit(2)
        }
        if args.contains("--job") {
            // The path a drop takes: JobCenter, HUD, history.
            JobCenter.shared.start(op, files: files)
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let center = JobCenter.shared
                    guard !center.isBusy, let record = center.records.last ?? nil else { return }
                    print("JOB \(record.state) -> \(record.outputs.map(\.lastPathComponent).joined(separator: " | ")) note: \(record.note ?? "")")
                    exit(record.state == .done ? 0 : 1)
                }
            }
            return
        }
        let settings = JobSettings.snapshot()
        Task {
            var failed = false
            // Written as if/else on purpose: the one-line ternary came out empty in -O builds (Swift 6.2).
            var batches: [[URL]] = []
            if op.batch == .all { batches.append(files) } else { batches = files.map { [$0] } }
            for batch in batches {
                let ctx = JobContext(inputs: batch, settings: settings) { _ in }
                let started = Date()
                do {
                    let out = try await op.run(ctx)
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    print("OK \(batch.map(\.lastPathComponent).joined(separator: ",")) -> \(out.map(\.path).joined(separator: " | ")) [\(ms) ms]\(ctx.note.map { " note: \($0)" } ?? "")")
                } catch {
                    failed = true
                    print("FAIL \(batch.map(\.lastPathComponent).joined(separator: ",")): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                }
                ctx.cleanUp()
            }
            exit(failed ? 1 : 0)
        }
    }
}
