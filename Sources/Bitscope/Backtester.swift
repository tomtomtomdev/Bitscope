import Foundation

// MARK: - Backtest Results

struct BacktestResult: Codable {
    var symbol: String
    var trades: [Trade]
    var totalReturn: Double       // Percentage
    var winRate: Double           // Percentage of winning trades
    var maxDrawdown: Double       // Maximum peak-to-trough decline
    var sharpeRatio: Double       // Risk-adjusted return
    var totalTrades: Int
    var winningTrades: Int
    var losingTrades: Int
    var avgHoldingDays: Double

    struct Trade: Codable {
        var entryDate: Date
        var exitDate: Date?
        var entrySignal: TradingSignal
        var exitSignal: TradingSignal?
        var entryStage: BandarFlowStage
        var exitStage: BandarFlowStage?
        var returnPct: Double?      // Simulated return
        var holdingDays: Int
    }
}

struct PortfolioBacktest: Codable {
    var startDate: Date
    var endDate: Date
    var initialCapital: Double
    var finalValue: Double
    var totalReturn: Double
    var cagr: Double              // Compound annual growth rate
    var maxDrawdown: Double
    var sharpeRatio: Double
    var sortino: Double           // Downside risk-adjusted return
    var stockResults: [BacktestResult]
    var totalTrades: Int
    var winRate: Double
    var avgReturn: Double
    var parameters: TradingModel.ModelParameters
}

// MARK: - Backtester

final class Backtester {
    private let model: TradingModel

    /// Simulated returns based on stage (for backtesting without price data)
    /// These are calibrated estimates based on typical stage behavior
    private let stageReturns: [BandarFlowStage: (mean: Double, stdDev: Double)] = [
        .accumulation: (0.08, 0.15),   // 8% avg return, 15% volatility
        .markup: (0.12, 0.20),          // 12% avg return during markup
        .distribution: (-0.03, 0.18),   // -3% as distribution starts
        .markdown: (-0.10, 0.25),       // -10% during markdown
        .unknown: (0.0, 0.10)           // Neutral
    ]

    init(model: TradingModel) {
        self.model = model
    }

    // MARK: - Single Stock Backtest

    func backtest(symbol: String, history: [ParsedStockData]) -> BacktestResult {
        var trades: [BacktestResult.Trade] = []
        var currentTrade: BacktestResult.Trade?

        for (index, data) in history.enumerated() {
            let stage = data.stage
            let signal = stage.signal

            // Entry logic: Buy on accumulation signal
            if currentTrade == nil && signal == .buy {
                currentTrade = BacktestResult.Trade(
                    entryDate: data.date,
                    exitDate: nil,
                    entrySignal: .buy,
                    exitSignal: nil,
                    entryStage: stage,
                    exitStage: nil,
                    returnPct: nil,
                    holdingDays: 0
                )
            }

            // Exit logic: Sell on distribution/markdown signal
            if var trade = currentTrade, (signal == .sell || signal == .avoid) {
                trade.exitDate = data.date
                trade.exitSignal = signal
                trade.exitStage = stage
                trade.holdingDays = Calendar.current.dateComponents(
                    [.day], from: trade.entryDate, to: data.date
                ).day ?? 0

                // Simulate return based on stages traversed
                trade.returnPct = simulateReturn(
                    entryStage: trade.entryStage,
                    exitStage: stage,
                    holdingDays: trade.holdingDays
                )

                trades.append(trade)
                currentTrade = nil
            }

            // Update holding days for open position
            if var trade = currentTrade, index == history.count - 1 {
                // Close any open position at end of data
                trade.exitDate = data.date
                trade.exitSignal = .neutral
                trade.exitStage = stage
                trade.holdingDays = Calendar.current.dateComponents(
                    [.day], from: trade.entryDate, to: data.date
                ).day ?? 0
                trade.returnPct = simulateReturn(
                    entryStage: trade.entryStage,
                    exitStage: stage,
                    holdingDays: trade.holdingDays
                )
                trades.append(trade)
            }
        }

        return calculateResults(symbol: symbol, trades: trades)
    }

    private func simulateReturn(entryStage: BandarFlowStage, exitStage: BandarFlowStage, holdingDays: Int) -> Double {
        // Base return from entry stage
        let (entryMean, _) = stageReturns[entryStage] ?? (0, 0.1)
        let (exitMean, _) = stageReturns[exitStage] ?? (0, 0.1)

        // Combine entry and exit stage effects
        let baseReturn = (entryMean + exitMean) / 2

        // Scale by holding period (roughly monthly returns)
        let periodFactor = Double(holdingDays) / 30.0

        // Add some randomness for realistic simulation
        let noise = Double.random(in: -0.05...0.05)

        return baseReturn * periodFactor + noise
    }

    private func calculateResults(symbol: String, trades: [BacktestResult.Trade]) -> BacktestResult {
        let returns = trades.compactMap { $0.returnPct }
        let winningReturns = returns.filter { $0 > 0 }
        let losingReturns = returns.filter { $0 <= 0 }

        let totalReturn = returns.reduce(0, +)
        let winRate = returns.isEmpty ? 0 : Double(winningReturns.count) / Double(returns.count) * 100

        // Calculate max drawdown
        var cumulative: [Double] = [0]
        for ret in returns {
            cumulative.append(cumulative.last! + ret)
        }
        var maxDrawdown = 0.0
        var peak = cumulative[0]
        for value in cumulative {
            peak = max(peak, value)
            let drawdown = (peak - value) / max(peak, 0.001)
            maxDrawdown = max(maxDrawdown, drawdown)
        }

        // Sharpe ratio (simplified)
        let avgReturn = returns.isEmpty ? 0 : returns.reduce(0, +) / Double(returns.count)
        let variance = returns.isEmpty ? 1 : returns.map { pow($0 - avgReturn, 2) }.reduce(0, +) / Double(returns.count)
        let stdDev = sqrt(variance)
        let sharpeRatio = stdDev > 0 ? avgReturn / stdDev : 0

        let avgHoldingDays = trades.isEmpty ? 0 : Double(trades.map { $0.holdingDays }.reduce(0, +)) / Double(trades.count)

        return BacktestResult(
            symbol: symbol,
            trades: trades,
            totalReturn: totalReturn * 100,
            winRate: winRate,
            maxDrawdown: maxDrawdown * 100,
            sharpeRatio: sharpeRatio,
            totalTrades: trades.count,
            winningTrades: winningReturns.count,
            losingTrades: losingReturns.count,
            avgHoldingDays: avgHoldingDays
        )
    }

    // MARK: - Portfolio Backtest

    func backtestPortfolio(
        stockHistory: [String: [ParsedStockData]],
        initialCapital: Double = 100_000_000  // 100M IDR
    ) -> PortfolioBacktest {
        var stockResults: [BacktestResult] = []
        var allTrades: [BacktestResult.Trade] = []

        for (symbol, history) in stockHistory where history.count >= 3 {
            let result = backtest(symbol: symbol, history: history)
            stockResults.append(result)
            allTrades.append(contentsOf: result.trades)
        }

        // Calculate portfolio metrics
        let allReturns = allTrades.compactMap { $0.returnPct }
        let totalReturn = allReturns.isEmpty ? 0 : allReturns.reduce(0, +)
        let avgReturn = allReturns.isEmpty ? 0 : totalReturn / Double(allReturns.count)
        let winRate = allReturns.isEmpty ? 0 :
            Double(allReturns.filter { $0 > 0 }.count) / Double(allReturns.count) * 100

        // Date range
        let allDates = stockHistory.values.flatMap { $0.map { $0.date } }
        let startDate = allDates.min() ?? Date()
        let endDate = allDates.max() ?? Date()
        let years = Double(max(1, Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 365)) / 365.0

        // CAGR
        let finalValue = initialCapital * (1 + totalReturn)
        let cagr = pow(finalValue / initialCapital, 1.0 / years) - 1

        // Portfolio Sharpe
        let variance = allReturns.isEmpty ? 1 :
            allReturns.map { pow($0 - avgReturn, 2) }.reduce(0, +) / Double(allReturns.count)
        let sharpeRatio = sqrt(variance) > 0 ? avgReturn / sqrt(variance) : 0

        // Sortino (downside deviation)
        let downsideReturns = allReturns.filter { $0 < 0 }
        let downsideVariance = downsideReturns.isEmpty ? 1 :
            downsideReturns.map { pow($0, 2) }.reduce(0, +) / Double(downsideReturns.count)
        let sortino = sqrt(downsideVariance) > 0 ? avgReturn / sqrt(downsideVariance) : 0

        // Max drawdown across portfolio
        let maxDrawdown = stockResults.isEmpty ? 0 : stockResults.map { $0.maxDrawdown }.max() ?? 0

        return PortfolioBacktest(
            startDate: startDate,
            endDate: endDate,
            initialCapital: initialCapital,
            finalValue: finalValue,
            totalReturn: totalReturn * 100,
            cagr: cagr * 100,
            maxDrawdown: maxDrawdown,
            sharpeRatio: sharpeRatio,
            sortino: sortino,
            stockResults: stockResults.sorted { $0.totalReturn > $1.totalReturn },
            totalTrades: allTrades.count,
            winRate: winRate,
            avgReturn: avgReturn * 100,
            parameters: model.parameters
        )
    }

    // MARK: - Parameter Optimization

    /// Simple grid search for optimal parameters
    func optimizeParameters(
        stockHistory: [String: [ParsedStockData]],
        iterations: Int = 10
    ) -> TradingModel.ModelParameters {
        var bestParams = model.parameters
        var bestReturn = -Double.infinity

        let confidenceRange = stride(from: 0.3, through: 0.7, by: 0.1)
        let momentumRange = stride(from: 0.4, through: 0.8, by: 0.1)

        for confidence in confidenceRange {
            for momentum in momentumRange {
                var testParams = model.parameters
                testParams.confidenceThreshold = confidence
                testParams.momentumWeight = momentum

                model.parameters = testParams
                let result = backtestPortfolio(stockHistory: stockHistory)

                // Optimize for risk-adjusted return
                let score = result.totalReturn - result.maxDrawdown * 0.5

                if score > bestReturn {
                    bestReturn = score
                    bestParams = testParams
                }
            }
        }

        model.parameters = bestParams
        return bestParams
    }

    // MARK: - Report Generation

    func generateBacktestReport(result: PortfolioBacktest) -> String {
        var lines: [String] = []

        lines.append("=" .padding(toLength: 70, withPad: "=", startingAt: 0))
        lines.append("BACKTEST REPORT - BANDAR FLOW TRADING MODEL")
        lines.append("=" .padding(toLength: 70, withPad: "=", startingAt: 0))
        lines.append("")

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        lines.append("Period: \(dateFormatter.string(from: result.startDate)) - \(dateFormatter.string(from: result.endDate))")
        lines.append("")

        lines.append("PORTFOLIO PERFORMANCE")
        lines.append("-".padding(toLength: 40, withPad: "-", startingAt: 0))
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        lines.append("  Initial Capital:   Rp \(formatter.string(from: NSNumber(value: result.initialCapital)) ?? "0")")
        lines.append("  Final Value:       Rp \(formatter.string(from: NSNumber(value: result.finalValue)) ?? "0")")
        lines.append(String(format: "  Total Return:      %.2f%%", result.totalReturn))
        lines.append(String(format: "  CAGR:              %.2f%%", result.cagr))
        lines.append("")

        lines.append("RISK METRICS")
        lines.append("-".padding(toLength: 40, withPad: "-", startingAt: 0))
        lines.append(String(format: "  Max Drawdown:      %.2f%%", result.maxDrawdown))
        lines.append(String(format: "  Sharpe Ratio:      %.2f", result.sharpeRatio))
        lines.append(String(format: "  Sortino Ratio:     %.2f", result.sortino))
        lines.append("")

        lines.append("TRADE STATISTICS")
        lines.append("-".padding(toLength: 40, withPad: "-", startingAt: 0))
        lines.append(String(format: "  Total Trades:      %d", result.totalTrades))
        lines.append(String(format: "  Win Rate:          %.1f%%", result.winRate))
        lines.append(String(format: "  Avg Return/Trade:  %.2f%%", result.avgReturn))
        lines.append("")

        lines.append("TOP PERFORMING STOCKS")
        lines.append("-".padding(toLength: 40, withPad: "-", startingAt: 0))
        for stock in result.stockResults.prefix(10) {
            lines.append(String(format: "  %s: %.2f%% (Win Rate: %.1f%%, %d trades)",
                                stock.symbol, stock.totalReturn, stock.winRate, stock.totalTrades))
        }
        lines.append("")

        lines.append("MODEL PARAMETERS")
        lines.append("-".padding(toLength: 40, withPad: "-", startingAt: 0))
        lines.append(String(format: "  Confidence Threshold: %.2f", result.parameters.confidenceThreshold))
        lines.append(String(format: "  Momentum Weight:      %.2f", result.parameters.momentumWeight))
        lines.append(String(format: "  Lookback Period:      %d days", result.parameters.lookbackPeriod))

        return lines.joined(separator: "\n")
    }
}
