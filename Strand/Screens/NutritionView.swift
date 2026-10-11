import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Nutrition tab (FORK-ONLY, not ported to Android)
//
// Daily protein/carb/fat targets (MacroTargets: weight + today's Effort/strain + today's energy
// estimate), a simple add-meal form (grams in, calories computed automatically), today's logged meals
// list, and a calorie surplus/deficit readout comparing what was eaten against what was burned. Mirrors
// HydrationView's screen shape (ScreenScaffold, frosted `card {}` surfaces, tap-to-edit/trash-to-delete
// rows) without the quick-tap buttons or hero vessel — the user types exact grams, so there is no
// "amount size" to offer back.
struct NutritionView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @State private var meals: [MealRow] = []
    @State private var reloadTick = 0
    @State private var showAddMeal = false
    @State private var editingMeal: MealRow?

    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    private var targets: MacroTargets.MacroTargetGrams { repo.macroTargets(weightKg: profile.weightKg) }
    private var eatenProteinG: Double { meals.reduce(0) { $0 + $1.proteinG } }
    private var eatenCarbsG: Double { meals.reduce(0) { $0 + $1.carbsG } }
    private var eatenFatG: Double { meals.reduce(0) { $0 + $1.fatG } }
    private var eatenKcal: Double { meals.reduce(0) { $0 + $1.caloriesKcal } }
    /// nil when today hasn't scored an energy estimate yet (no HR today) — the surplus/deficit card
    /// must show that honestly rather than assume a zero burn.
    private var burnedKcal: Double? { repo.today?.activeKcalEst }

    var body: some View {
        ScreenScaffold(title: "Nutrition",
                       subtitle: "Today's macros, on \(Platform.deviceNounPhrase) only.",
                       onRefresh: { await reload() },
                       topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                targetsSection
                balanceSection
                addMealButton
                mealsSection
                Text("Targets are an approximate guide from your weight and today's effort — not medical or dietetic advice.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: reloadTick) { await reload() }
        .sheet(isPresented: $showAddMeal) {
            MealEntrySheet(title: "Add meal", meal: nil) { name, p, c, f in
                showAddMeal = false
                Task { await save(name: name, proteinG: p, carbsG: c, fatG: f) }
            } onCancel: { showAddMeal = false }
        }
        .sheet(item: $editingMeal) { meal in
            MealEntrySheet(title: "Edit meal", meal: meal) { name, p, c, f in
                editingMeal = nil
                Task { await save(id: meal.id, loggedAt: meal.loggedAt, name: name, proteinG: p, carbsG: c, fatG: f) }
            } onCancel: { editingMeal = nil }
        }
    }

    // MARK: - Frosted card helper (matches HydrationView.card)

    private func card<V: View>(padding: CGFloat = 16, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoopPanelSurface(cornerRadius: 22, surfaceOpacity: cardOpacity))
    }

    // MARK: - Targets vs. eaten

    private var targetsSection: some View {
        card(padding: 18) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Today's macros").strandOverline()
                macroRow("Protein", eaten: eatenProteinG, target: targets.proteinG, tint: StrandPalette.metricRose)
                macroRow("Carbs", eaten: eatenCarbsG, target: targets.carbsG, tint: StrandPalette.metricCyan)
                macroRow("Fat", eaten: eatenFatG, target: targets.fatG, tint: StrandPalette.metricAmber)
            }
        }
    }

    private func macroRow(_ label: LocalizedStringKey, eaten: Double, target: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text("\(Int(eaten.rounded()))g / \(target)g")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
            }
            LiquidTube(frac: target > 0 ? min(1.0, eaten / Double(target)) : 0, tint: tint, height: 8, animated: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(Int(eaten.rounded())) of \(target) grams")
    }

    // MARK: - Calorie surplus/deficit

    private static let balanceBandKcal = 25.0

    @ViewBuilder private var balanceSection: some View {
        card(padding: 18) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Calorie balance").strandOverline()
                if let burnedKcal {
                    let delta = eatenKcal - burnedKcal
                    HStack(spacing: 10) {
                        Image(systemName: delta > Self.balanceBandKcal ? "arrow.up.circle.fill"
                              : delta < -Self.balanceBandKcal ? "arrow.down.circle.fill" : "equal.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(delta > Self.balanceBandKcal ? StrandPalette.metricAmber
                                              : delta < -Self.balanceBandKcal ? StrandPalette.metricCyan
                                              : StrandPalette.textSecondary)
                        Text(balanceHeadline(delta))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text("Eaten \(Int(eatenKcal.rounded())) kcal · Burned \(Int(burnedKcal.rounded())) kcal")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("Eaten \(Int(eatenKcal.rounded())) kcal")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Burned: not enough heart-rate data yet today.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func balanceHeadline(_ delta: Double) -> String {
        if delta > Self.balanceBandKcal {
            return String(localized: "+\(Int(delta.rounded())) kcal surplus")
        }
        if delta < -Self.balanceBandKcal {
            return String(localized: "\(Int(delta.rounded())) kcal deficit")
        }
        return String(localized: "Balanced")
    }

    // MARK: - Add meal

    private var addMealButton: some View {
        NoopButton("Add meal", systemImage: "plus.circle.fill", kind: .secondary, fullWidth: true) {
            showAddMeal = true
        }
    }

    // MARK: - Today's meals - tap to edit, trash to delete

    @ViewBuilder private var mealsSection: some View {
        if !meals.isEmpty {
            card(padding: 18) {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    Text("Today's meals").strandOverline()
                    VStack(spacing: 0) {
                        ForEach(Array(meals.enumerated()), id: \.element.id) { idx, meal in
                            mealRow(meal)
                                .padding(.vertical, 6)
                            if idx < meals.count - 1 {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                    Text("Tap a meal to edit it, or use the trash to delete.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func mealRow(_ meal: MealRow) -> some View {
        HStack(spacing: 10) {
            Button { editingMeal = meal } label: {
                HStack(spacing: 10) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meal.name?.isEmpty == false ? meal.name! : String(localized: "Meal"))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("\(Self.entryTimeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(meal.loggedAt)))) · "
                             + "\(Int(meal.proteinG.rounded()))g P · \(Int(meal.carbsG.rounded()))g C · \(Int(meal.fatG.rounded()))g F")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Text("\(Int(meal.caloriesKcal.rounded())) kcal")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityLabel("\(meal.name?.isEmpty == false ? meal.name! : "Meal"), \(Int(meal.caloriesKcal.rounded())) calories")
            .accessibilityHint("Tap to edit")
            Button(role: .destructive) {
                Task { await delete(meal) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete this meal")
        }
    }

    private static var entryTimeFmt: DateFormatter { AppClock.hourMinuteFormatter() }

    // MARK: - Data

    private func reload() async {
        meals = await repo.meals()
    }

    private func save(id: String = UUID().uuidString, loggedAt: Int = Int(Date().timeIntervalSince1970),
                      name: String?, proteinG: Double, carbsG: Double, fatG: Double) async {
        _ = await repo.saveMeal(id: id, loggedAt: loggedAt, name: name,
                                proteinG: proteinG, carbsG: carbsG, fatG: fatG)
        reloadTick &+= 1
    }

    private func delete(_ meal: MealRow) async {
        _ = await repo.deleteMeal(id: meal.id)
        reloadTick &+= 1
    }
}

// MARK: - Add/edit meal sheet

/// Carbs/protein/fat in grams (+ optional name) — the user types exact numbers, calories compute live.
private struct MealEntrySheet: View {
    let title: LocalizedStringKey
    let onSave: (_ name: String?, _ proteinG: Double, _ carbsG: Double, _ fatG: Double) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var proteinText: String
    @State private var carbsText: String
    @State private var fatText: String

    init(title: LocalizedStringKey, meal: MealRow?,
         onSave: @escaping (_ name: String?, _ proteinG: Double, _ carbsG: Double, _ fatG: Double) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: meal?.name ?? "")
        _proteinText = State(initialValue: meal.map { Self.format($0.proteinG) } ?? "")
        _carbsText = State(initialValue: meal.map { Self.format($0.carbsG) } ?? "")
        _fatText = State(initialValue: meal.map { Self.format($0.fatG) } ?? "")
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    private var proteinG: Double { Double(proteinText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var carbsG: Double { Double(carbsText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var fatG: Double { Double(fatText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var previewKcal: Double { MacroTargets.kcal(proteinG: proteinG, carbsG: carbsG, fatG: fatG) }
    private var canSave: Bool { proteinG > 0 || carbsG > 0 || fatG > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            Text(title)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)

            TextField("Meal name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)

            gramField("Protein (g)", text: $proteinText)
            gramField("Carbs (g)", text: $carbsText)
            gramField("Fat (g)", text: $fatText)

            HStack {
                Text("Calories")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text("\(Int(previewKcal.rounded())) kcal")
                    .font(StrandFont.rounded(24, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
            }

            HStack(spacing: NoopMetrics.gap) {
                NoopButton("Cancel", kind: .secondary, fullWidth: true) { onCancel() }
                NoopButton("Save", kind: .primary, fullWidth: true) {
                    onSave(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name,
                          proteinG, carbsG, fatG)
                }
                .disabled(!canSave)
            }
        }
        .padding(NoopMetrics.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        #if os(iOS)
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func gramField(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            TextField("0", text: text)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .multilineTextAlignment(.trailing)
                .font(StrandFont.subhead.weight(.semibold))
                .frame(width: 80)
        }
    }
}
