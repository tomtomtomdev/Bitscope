import Foundation

// MARK: - Bandar Flow Stages (Wyckoff-inspired)

/// Institutional money flow follows predictable stages:
/// 1. Accumulation - Smart money quietly buys, foreign flow turns positive
/// 2. Markup - Price rises with strong foreign buying, momentum builds
/// 3. Distribution - Smart money sells to retail, foreign flow weakens
/// 4. Markdown - Price falls, foreign flow negative
enum BandarFlowStage: String, Codable, CaseIterable {
    case accumulation   // Early entry - foreign flow turning positive
    case markup         // Strong trend - sustained foreign buying
    case distribution   // Exit warning - foreign flow weakening
    case markdown       // Avoid - foreign outflow
    case unknown        // Insufficient data

    var signal: TradingSignal {
        switch self {
        case .accumulation: return .buy
        case .markup: return .hold
        case .distribution: return .sell
        case .markdown: return .avoid
        case .unknown: return .neutral
        }
    }

    var description: String {
        switch self {
        case .accumulation: return "Accumulation (BUY zone)"
        case .markup: return "Markup (HOLD/ADD)"
        case .distribution: return "Distribution (SELL zone)"
        case .markdown: return "Markdown (AVOID)"
        case .unknown: return "Unknown"
        }
    }
}

enum TradingSignal: String, Codable {
    case buy, hold, sell, avoid, neutral

    var emoji: String {
        switch self {
        case .buy: return "🟢"
        case .hold: return "🔵"
        case .sell: return "🔴"
        case .avoid: return "⚫"
        case .neutral: return "⚪"
        }
    }
}

// MARK: - Parsed Stock Data

struct ParsedStockData: Codable {
    var symbol: String
    var date: Date
    var netForeignBuy: Double?      // Raw value in billions
    var netForeignBuyChange: Double? // Percentage change
    var foreignFlow: Double?         // Flow value
    var foreignFlowMA20: Double?     // 20-day MA
    var foreignFlowChange: Double?   // Percentage change
    var rank: Int?
    var screenerType: String?

    // Computed stage based on flow patterns
    var stage: BandarFlowStage {
        detectStage()
    }

    private func detectStage() -> BandarFlowStage {
        // Need foreign flow data to determine stage
        guard let flow = foreignFlow else { return .unknown }

        let flowPositive = flow > 0
        let flowChangePositive = (foreignFlowChange ?? 0) > 0
        let flowAboveMA = foreignFlowMA20.map { flow > $0 } ?? false
        let buyingStrength = (netForeignBuyChange ?? 0) > 0

        // Stage detection logic based on Wyckoff principles
        if flowPositive && flowChangePositive && buyingStrength {
            // Strong buying with increasing momentum
            return flowAboveMA ? .markup : .accumulation
        } else if flowPositive && !flowChangePositive {
            // Positive but weakening - distribution
            return .distribution
        } else if !flowPositive && !flowChangePositive {
            // Negative and getting worse
            return .markdown
        } else if !flowPositive && flowChangePositive {
            // Negative but improving - early accumulation
            return .accumulation
        }

        return .unknown
    }
}

// MARK: - Stock Analysis Result

struct StockAnalysis: Codable {
    var symbol: String
    var stage: BandarFlowStage
    var signal: TradingSignal
    var confidence: Double  // 0.0 - 1.0
    var dataPoints: Int
    var latestData: ParsedStockData?
    var flowTrend: [Double]  // Recent flow values for trend analysis
    var recommendation: String

    static func analyze(symbol: String, history: [ParsedStockData]) -> StockAnalysis {
        guard !history.isEmpty else {
            return StockAnalysis(
                symbol: symbol,
                stage: .unknown,
                signal: .neutral,
                confidence: 0,
                dataPoints: 0,
                latestData: nil,
                flowTrend: [],
                recommendation: "Insufficient data"
            )
        }

        let latest = history.last!
        let stage = latest.stage
        let flowTrend = history.compactMap { $0.foreignFlow }

        // Calculate confidence based on data consistency
        let stageVotes = history.suffix(5).map { $0.stage }
        let stageConsensus = Double(stageVotes.filter { $0 == stage }.count) / Double(stageVotes.count)

        // Trend strength
        let trendStrength: Double
        if flowTrend.count >= 2 {
            let recentAvg = flowTrend.suffix(3).reduce(0, +) / Double(min(3, flowTrend.count))
            let olderAvg = flowTrend.prefix(max(1, flowTrend.count - 3)).reduce(0, +) / Double(max(1, flowTrend.count - 3))
            trendStrength = olderAvg != 0 ? min(1, abs((recentAvg - olderAvg) / olderAvg)) : 0.5
        } else {
            trendStrength = 0.3
        }

        let confidence = (stageConsensus * 0.6 + trendStrength * 0.4)

        let recommendation = generateRecommendation(stage: stage, confidence: confidence, symbol: symbol)

        return StockAnalysis(
            symbol: symbol,
            stage: stage,
            signal: stage.signal,
            confidence: confidence,
            dataPoints: history.count,
            latestData: latest,
            flowTrend: flowTrend,
            recommendation: recommendation
        )
    }

    private static func generateRecommendation(stage: BandarFlowStage, confidence: Double, symbol: String) -> String {
        let confLevel = confidence > 0.7 ? "High" : confidence > 0.4 ? "Medium" : "Low"

        switch stage {
        case .accumulation:
            return "\(symbol): \(confLevel) confidence BUY - Institutional accumulation detected"
        case .markup:
            return "\(symbol): \(confLevel) confidence HOLD - Strong uptrend, consider adding on dips"
        case .distribution:
            return "\(symbol): \(confLevel) confidence SELL - Distribution pattern, take profits"
        case .markdown:
            return "\(symbol): AVOID - Institutional selling, wait for accumulation"
        case .unknown:
            return "\(symbol): NEUTRAL - Insufficient data for analysis"
        }
    }
}

// MARK: - Trading Model

final class TradingModel {
    private(set) var stockHistory: [String: [ParsedStockData]] = [:]
    private let dataURL: URL
    private let historyURL: URL

    // Model parameters (can be tuned via training)
    var parameters = ModelParameters()

    struct ModelParameters: Codable {
        var flowThreshold: Double = 0.0          // Positive flow threshold
        var momentumWeight: Double = 0.6         // Weight for momentum vs absolute flow
        var lookbackPeriod: Int = 5              // Days to look back for trend
        var minDataPoints: Int = 3               // Minimum data points for signal
        var confidenceThreshold: Double = 0.5   // Minimum confidence for actionable signal
    }

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let base = support.appendingPathComponent("Bitscope/trading", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)

        dataURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/stock-picks.json")
        historyURL = base.appendingPathComponent("stock-history.json")

        loadHistory()
    }

    // MARK: - Data Loading

    /// Load historical stock data from persistent storage
    func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let history = try? JSONDecoder().decode([String: [ParsedStockData]].self, from: data) else {
            return
        }
        stockHistory = history
    }

    /// Save historical data
    func saveHistory() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(stockHistory) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    /// Import new data from stock-picks.json
    func importLatestData() -> Int {
        guard let data = try? Data(contentsOf: dataURL),
              let screeners = try? JSONDecoder().decode([ScreenerData].self, from: data) else {
            return 0
        }

        var imported = 0
        let today = Date()

        for screener in screeners {
            for stock in screener.stocks {
                let parsed = parseStockPick(stock, screenerType: screener.screenerType, date: today)

                if stockHistory[parsed.symbol] == nil {
                    stockHistory[parsed.symbol] = []
                }

                // Avoid duplicates for same day
                let isDuplicate = stockHistory[parsed.symbol]?.contains {
                    Calendar.current.isDate($0.date, inSameDayAs: today)
                } ?? false

                if !isDuplicate {
                    stockHistory[parsed.symbol]?.append(parsed)
                    imported += 1
                }
            }
        }

        if imported > 0 {
            saveHistory()
        }

        return imported
    }

    private struct ScreenerData: Codable {
        var file: String
        var screenerType: String?
        var stocks: [RawStockPick]
    }

    private struct RawStockPick: Codable {
        var symbol: String
        var rank: Int?
        var netForeignBuy: String?
        var foreignFlow: String?
        var foreignFlowMA20: String?
        var value: String?
    }

    private func parseStockPick(_ raw: RawStockPick, screenerType: String?, date: Date) -> ParsedStockData {
        ParsedStockData(
            symbol: raw.symbol,
            date: date,
            netForeignBuy: parseValue(raw.netForeignBuy),
            netForeignBuyChange: parsePercentage(raw.netForeignBuy),
            foreignFlow: parseValue(raw.foreignFlow),
            foreignFlowMA20: parseValue(raw.foreignFlowMA20),
            foreignFlowChange: parsePercentage(raw.foreignFlow),
            rank: raw.rank,
            screenerType: screenerType
        )
    }

    private func parseValue(_ str: String?) -> Double? {
        guard let str = str else { return nil }

        // Extract numeric value, handling B/T/M suffixes
        var cleaned = str
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespaces)

        var multiplier: Double = 1

        if cleaned.hasSuffix("T") {
            multiplier = 1_000_000_000_000
            cleaned = String(cleaned.dropLast())
        } else if cleaned.hasSuffix("B") {
            multiplier = 1_000_000_000
            cleaned = String(cleaned.dropLast())
        } else if cleaned.hasSuffix("M") {
            multiplier = 1_000_000
            cleaned = String(cleaned.dropLast())
        }

        // Extract first number found
        let pattern = #"-?[\d.]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let range = Range(match.range, in: cleaned),
              let value = Double(cleaned[range]) else {
            return nil
        }

        return value * multiplier
    }

    private func parsePercentage(_ str: String?) -> Double? {
        guard let str = str else { return nil }

        // Look for percentage in parentheses like (+27.04%) or (-14.21%)
        let pattern = #"\(([+-]?[\d.]+)%\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: str),
              let value = Double(str[range]) else {
            return nil
        }

        return value
    }

    // MARK: - Analysis

    /// Analyze all stocks and return sorted by signal strength
    func analyzeAll() -> [StockAnalysis] {
        stockHistory.map { symbol, history in
            StockAnalysis.analyze(symbol: symbol, history: history)
        }
        .filter { $0.dataPoints >= parameters.minDataPoints }
        .sorted { a, b in
            // Sort by signal priority, then confidence
            let signalOrder: [TradingSignal: Int] = [.buy: 0, .hold: 1, .sell: 2, .avoid: 3, .neutral: 4]
            let aOrder = signalOrder[a.signal] ?? 5
            let bOrder = signalOrder[b.signal] ?? 5
            if aOrder != bOrder { return aOrder < bOrder }
            return a.confidence > b.confidence
        }
    }

    /// Get top picks for each signal type
    func getTopPicks(limit: Int = 5) -> [TradingSignal: [StockAnalysis]] {
        let all = analyzeAll()
        var result: [TradingSignal: [StockAnalysis]] = [:]

        for signal in [TradingSignal.buy, .hold, .sell] {
            result[signal] = all
                .filter { $0.signal == signal && $0.confidence >= parameters.confidenceThreshold }
                .prefix(limit)
                .map { $0 }
        }

        return result
    }

    /// Generate daily report
    func generateReport() -> String {
        let picks = getTopPicks()
        var lines: [String] = []

        lines.append("=" .padding(toLength: 60, withPad: "=", startingAt: 0))
        lines.append("BANDAR FLOW TRADING REPORT - \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))")
        lines.append("=" .padding(toLength: 60, withPad: "=", startingAt: 0))
        lines.append("")

        // BUY signals
        if let buys = picks[.buy], !buys.isEmpty {
            lines.append("🟢 BUY SIGNALS (Accumulation Phase)")
            lines.append("-".padding(toLength: 40, withPad: "-", startingAt: 0))
            for stock in buys {
                lines.append("  \(stock.symbol): Confidence \(String(format: "%.0f%%", stock.confidence * 100))")
                lines.append("    \(stock.recommendation)")
            }
            lines.append("")
        }

        // HOLD signals
        if let holds = picks[.hold], !holds.isEmpty {
            lines.append("🔵 HOLD SIGNALS (Markup Phase)")
            lines.append("-".padding(toLength: 40, withPad: "-", startingAt: 0))
            for stock in holds {
                lines.append("  \(stock.symbol): Confidence \(String(format: "%.0f%%", stock.confidence * 100))")
            }
            lines.append("")
        }

        // SELL signals
        if let sells = picks[.sell], !sells.isEmpty {
            lines.append("🔴 SELL SIGNALS (Distribution Phase)")
            lines.append("-".padding(toLength: 40, withPad: "-", startingAt: 0))
            for stock in sells {
                lines.append("  \(stock.symbol): Confidence \(String(format: "%.0f%%", stock.confidence * 100))")
                lines.append("    \(stock.recommendation)")
            }
            lines.append("")
        }

        lines.append("Total stocks tracked: \(stockHistory.count)")
        lines.append("Data points: \(stockHistory.values.map { $0.count }.reduce(0, +))")

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON Output

    func exportAnalysisJSON() -> String {
        let analysis = analyzeAll()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        struct AnalysisReport: Codable {
            var generatedAt: Date
            var totalStocks: Int
            var buySignals: [StockAnalysis]
            var holdSignals: [StockAnalysis]
            var sellSignals: [StockAnalysis]
            var avoidSignals: [StockAnalysis]
        }

        let report = AnalysisReport(
            generatedAt: Date(),
            totalStocks: analysis.count,
            buySignals: analysis.filter { $0.signal == .buy },
            holdSignals: analysis.filter { $0.signal == .hold },
            sellSignals: analysis.filter { $0.signal == .sell },
            avoidSignals: analysis.filter { $0.signal == .avoid }
        )

        guard let data = try? encoder.encode(report),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
