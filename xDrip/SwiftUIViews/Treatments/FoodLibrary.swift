//
//  FoodLibrary.swift
//  xdrip
//
//  A food library for carb entries, after JugglucoNG 1.3 (GPL-3.0, see THIRD_PARTY_NOTICES.md):
//  its 232 staple foods (`Common/src/mobile/assets/foods/staples.tsv`, English and Ukrainian
//  names), custom foods, meals built from several ingredients, and packaged products from Open
//  Food Facts by search or barcode (`data/food/OpenFoodFacts.kt`).
//

import SwiftUI
import VisionKit

// MARK: - Model

/// A household portion of a food, e.g. one piece = 182 g.
struct FoodPortion: Codable, Hashable {
    let name: String
    let grams: Double

    /// Localised name of the staple portions; other names are shown as they are.
    var title: String {
        switch name {
        case "piece": return ExperimentalTexts.text("food.portion.piece", "piece")
        case "cup": return ExperimentalTexts.text("food.portion.cup", "cup")
        case "tbsp": return ExperimentalTexts.text("food.portion.tbsp", "tbsp")
        case "tsp": return ExperimentalTexts.text("food.portion.tsp", "tsp")
        case "glass": return ExperimentalTexts.text("food.portion.glass", "glass")
        case "slice": return ExperimentalTexts.text("food.portion.slice", "slice")
        case "serving": return ExperimentalTexts.text("food.portion.serving", "serving")
        default: return name
        }
    }
}

/// A food with its carbohydrate, protein and fat per 100 g (or 100 ml).
struct FoodItem: Codable, Hashable, Identifiable {
    enum Source: String, Codable { case staple, custom, openFoodFacts }

    let key: String
    var name: String
    var carbsPer100: Double
    var proteinPer100: Double
    var fatPer100: Double
    var portions: [FoodPortion] = []
    var source: Source = .custom

    var id: String { key }

    func carbs(grams: Double) -> Double { carbsPer100 * grams / 100 }
    func protein(grams: Double) -> Double { proteinPer100 * grams / 100 }
    func fat(grams: Double) -> Double { fatPer100 * grams / 100 }
}

/// One food of a meal with its amount.
struct MealIngredient: Identifiable, Hashable {
    let id = UUID()
    let food: FoodItem
    var grams: Double
}

/// What a meal adds up to.
struct MealTotals: Equatable {
    var carbs = 0.0
    var protein = 0.0
    var fat = 0.0

    init(_ ingredients: [MealIngredient] = []) {
        for ingredient in ingredients where ingredient.grams.isFinite && ingredient.grams > 0 {
            carbs += ingredient.food.carbs(grams: ingredient.grams)
            protein += ingredient.food.protein(grams: ingredient.grams)
            fat += ingredient.food.fat(grams: ingredient.grams)
        }
    }
}

// MARK: - Library

enum FoodLibrary {
    static let customKey = "experimentalFoodLibraryCustom"
    static let recentKey = "experimentalFoodLibraryRecent"
    static let maximumRecent = 30

    /// JugglucoNG's staple foods, named in Ukrainian on a Ukrainian device and in English otherwise.
    static let staples: [FoodItem] = parseStaples(stapleTable, ukrainian: Locale.preferredLanguages.first?.hasPrefix("uk") == true)

    /// key|carbs|protein|fat|portions|English|Ukrainian, values per 100 g.
    static func parseStaples(_ table: String, ukrainian: Bool) -> [FoodItem] {
        table.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, let carbs = Double(fields[1]), let protein = Double(fields[2]), let fat = Double(fields[3]) else { return nil }
            let portions = fields[4].split(separator: ",").compactMap { part -> FoodPortion? in
                let pair = part.split(separator: ":")
                guard pair.count == 2, let grams = Double(pair[1]), grams > 0 else { return nil }
                return FoodPortion(name: String(pair[0]), grams: grams)
            }
            let name = ukrainian && !fields[6].isEmpty ? fields[6] : fields[5]
            return FoodItem(key: "staple:" + fields[0], name: name, carbsPer100: carbs, proteinPer100: protein, fatPer100: fat,
                            portions: portions, source: .staple)
        }
    }

    static func custom(defaults: UserDefaults = .standard) -> [FoodItem] {
        guard let data = defaults.data(forKey: customKey) else { return [] }
        return (try? JSONDecoder().decode([FoodItem].self, from: data)) ?? []
    }

    static func setCustom(_ foods: [FoodItem], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(foods) { defaults.set(data, forKey: customKey) }
    }

    /// Adds or replaces a food of your own (also how an Open Food Facts product is kept for offline use).
    static func save(_ food: FoodItem, defaults: UserDefaults = .standard) {
        var foods = custom(defaults: defaults).filter { $0.key != food.key }
        foods.insert(food, at: 0)
        setCustom(foods, defaults: defaults)
    }

    static func delete(key: String, defaults: UserDefaults = .standard) {
        setCustom(custom(defaults: defaults).filter { $0.key != key }, defaults: defaults)
        var recent = recentGrams(defaults: defaults)
        recent.removeAll { $0.key == key }
        setRecent(recent, defaults: defaults)
    }

    // Recent foods remember the amount last used.

    struct Recent: Codable, Hashable {
        let key: String
        let grams: Double
    }

    static func recentGrams(defaults: UserDefaults = .standard) -> [Recent] {
        guard let data = defaults.data(forKey: recentKey) else { return [] }
        return (try? JSONDecoder().decode([Recent].self, from: data)) ?? []
    }

    private static func setRecent(_ recent: [Recent], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(recent) { defaults.set(data, forKey: recentKey) }
    }

    static func remember(_ ingredients: [MealIngredient], defaults: UserDefaults = .standard) {
        var recent = recentGrams(defaults: defaults)
        for ingredient in ingredients where ingredient.grams > 0 {
            recent.removeAll { $0.key == ingredient.food.key }
            recent.insert(Recent(key: ingredient.food.key, grams: ingredient.grams), at: 0)
        }
        setRecent(Array(recent.prefix(maximumRecent)), defaults: defaults)
    }

    /// Custom foods first, then the staples.
    static func all(defaults: UserDefaults = .standard) -> [FoodItem] { custom(defaults: defaults) + staples }

    /// Foods whose name contains every word of `query`, ignoring case and diacritics; names that
    /// start with the query come first. An empty query lists the recent foods, then everything.
    static func search(_ query: String, in foods: [FoodItem], recent: [Recent] = []) -> [FoodItem] {
        let words = normalized(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else {
            let byKey = Dictionary(foods.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let recentFoods = recent.compactMap { byKey[$0.key] }
            let recentKeys = Set(recentFoods.map(\.key))
            return recentFoods + foods.filter { !recentKeys.contains($0.key) }
        }
        let matches = foods.filter { food in
            let name = normalized(food.name)
            return words.allSatisfy { name.contains($0) }
        }
        let prefix = words.joined(separator: " ")
        return matches.filter { normalized($0.name).hasPrefix(prefix) } + matches.filter { !normalized($0.name).hasPrefix(prefix) }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The amount a picked food starts with: the last one used, else its first portion, else 100 g.
    static func defaultGrams(for food: FoodItem, recent: [Recent]) -> Double {
        recent.first { $0.key == food.key }?.grams ?? food.portions.first?.grams ?? 100
    }
}

// MARK: - Open Food Facts

/// Open Food Facts: open data on packaged products, no key. Nothing is sent until asked: a search
/// sends the typed words, a scan sends the barcode, and neither carries anything about the person.
/// The project asks apps to keep to about ten searches a minute, so searching is on a button.
enum OpenFoodFacts {
    static let keyPrefix = "off:"
    static let userAgent = "xDrip4iOS-fork (https://github.com/VolodymyrFihurniak/xdripswift)"
    static let fields = "code,product_name,product_name_uk,product_name_en,generic_name,brands,serving_size,serving_quantity,nutriments"

    static func productURL(barcode: String) -> URL? {
        URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json?fields=\(fields)")
    }

    static func searchURL(query: String, language: String) -> URL? {
        var components = URLComponents(string: "https://search.openfoodfacts.org/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
                                  URLQueryItem(name: "langs", value: language == "en" ? "en" : language + ",en"),
                                  URLQueryItem(name: "page_size", value: "24"),
                                  URLQueryItem(name: "fields", value: fields)]
        return components?.url
    }

    /// A barcode as Open Food Facts stores it: digits only, 8 to 14 of them.
    static func normalizedBarcode(_ text: String) -> String? {
        let digits = text.filter { $0.isASCII && $0.isNumber }
        return (8...14).contains(digits.count) && digits.count == text.trimmingCharacters(in: .whitespacesAndNewlines).count ? digits : nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let text = value as? String { return Double(text.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    /// One product as a food. A product without a carbohydrate figure is dropped: a food that
    /// cannot be counted is worse than no result.
    static func food(from product: [String: Any], language: String) -> FoodItem? {
        guard let code = (product["code"] as? String)?.trimmingCharacters(in: .whitespaces), !code.isEmpty, code.allSatisfy({ $0.isASCII && $0.isNumber }),
              let nutriments = product["nutriments"] as? [String: Any], let carbs = number(nutriments["carbohydrates_100g"]), carbs >= 0 else { return nil }
        let names = ["product_name_" + language, "product_name", "product_name_en", "generic_name"]
            .compactMap { (product[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard var name = names.first(where: { !$0.isEmpty }) else { return nil }
        if let brand = (product["brands"] as? String)?.split(separator: ",").first.map({ $0.trimmingCharacters(in: .whitespaces) }), !brand.isEmpty,
           !name.localizedCaseInsensitiveContains(brand) {
            name += " (" + brand + ")"
        }
        var portions: [FoodPortion] = []
        if let serving = number(product["serving_quantity"]), serving > 0 { portions.append(FoodPortion(name: "serving", grams: serving)) }
        return FoodItem(key: keyPrefix + code, name: name, carbsPer100: min(carbs, 100),
                        proteinPer100: min(max(number(nutriments["proteins_100g"]) ?? 0, 0), 100),
                        fatPer100: min(max(number(nutriments["fat_100g"]) ?? 0, 0), 100), portions: portions, source: .openFoodFacts)
    }

    static func parseProduct(_ data: Data, language: String) -> FoodItem? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (root["status"] as? Int) == 1,
              let product = root["product"] as? [String: Any] else { return nil }
        return food(from: product, language: language)
    }

    static func parseSearch(_ data: Data, language: String) -> [FoodItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let hits = root["hits"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return hits.compactMap { food(from: $0, language: language) }.filter { seen.insert($0.key).inserted }
    }

    private static func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static var language: String { Locale.preferredLanguages.first?.hasPrefix("uk") == true ? "uk" : "en" }

    /// nil when the product is not in Open Food Facts or has no carbohydrate figure.
    static func product(barcode: String) async throws -> FoodItem? {
        guard let url = productURL(barcode: barcode) else { return nil }
        let (data, status) = try await get(url)
        guard (200..<300).contains(status) else { return nil }
        return parseProduct(data, language: language)
    }

    static func search(_ query: String) async throws -> [FoodItem] {
        guard let url = searchURL(query: query, language: language) else { return [] }
        let (data, status) = try await get(url)
        guard (200..<300).contains(status) else { return [] }
        return parseSearch(data, language: language)
    }
}

// MARK: - Picker

/// Builds a meal from the library and hands back its carbs, protein and fat.
struct FoodPickerView: View {
    let onDone: (MealTotals) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var meal: [MealIngredient] = []
    @State private var custom = FoodLibrary.custom()
    @State private var online: [FoodItem] = []
    @State private var isSearchingOnline = false
    @State private var message: String?
    @State private var showsScanner = false
    @State private var showsEditor = false
    private let recent = FoodLibrary.recentGrams()

    private var results: [FoodItem] { Array(FoodLibrary.search(query, in: custom + FoodLibrary.staples, recent: recent).prefix(60)) }
    private var totals: MealTotals { MealTotals(meal) }

    var body: some View {
        NavigationStack {
            List {
                if !meal.isEmpty {
                    Section(header: Text(ExperimentalTexts.text("food.meal", "Meal")), footer: Text(totalsText)) {
                        ForEach($meal) { $ingredient in
                            FoodIngredientRow(ingredient: $ingredient)
                        }
                        .onDelete { meal.remove(atOffsets: $0) }
                    }
                }
                Section {
                    TextField(ExperimentalTexts.text("food.search", "Search foods"), text: $query)
                        .autocorrectionDisabled()
                    Button {
                        Task { await searchOnline() }
                    } label: {
                        HStack {
                            Label(ExperimentalTexts.text("food.searchOnline", "Search Open Food Facts"), systemImage: "globe")
                            if isSearchingOnline { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(query.trimmingCharacters(in: .whitespaces).count < 2 || isSearchingOnline)
                    if DataScannerViewController.isSupported {
                        Button { showsScanner = true } label: {
                            Label(ExperimentalTexts.text("food.scan", "Scan a barcode"), systemImage: "barcode.viewfinder")
                        }
                    }
                    Button { showsEditor = true } label: {
                        Label(ExperimentalTexts.text("food.new", "New food"), systemImage: "plus")
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                if !online.isEmpty {
                    Section(header: Text("Open Food Facts")) {
                        ForEach(online) { food in foodRow(food, keepsOffline: true) }
                    }
                }
                Section(header: Text(ExperimentalTexts.text("food.library", "Food library"))) {
                    ForEach(results) { food in
                        foodRow(food, keepsOffline: false)
                            .swipeActions {
                                if food.source != .staple {
                                    Button(Texts_Common.delete, role: .destructive) {
                                        FoodLibrary.delete(key: food.key)
                                        custom = FoodLibrary.custom()
                                    }
                                }
                            }
                    }
                }
            }
            .navigationTitle(ExperimentalTexts.text("food.library", "Food library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Texts_Common.Cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ExperimentalTexts.text("food.use", "Use")) {
                        FoodLibrary.remember(meal)
                        onDone(totals)
                        dismiss()
                    }
                    .disabled(meal.isEmpty)
                }
            }
            .sheet(isPresented: $showsScanner) {
                FoodBarcodeScannerView { barcode in
                    showsScanner = false
                    Task { await lookUp(barcode: barcode) }
                }
            }
            .sheet(isPresented: $showsEditor) {
                FoodEditorView(name: query) { food in
                    FoodLibrary.save(food)
                    custom = FoodLibrary.custom()
                    add(food)
                }
            }
        }
    }

    private var totalsText: String {
        String(format: ExperimentalTexts.text("food.totals", "Carbs %@ · protein %@ · fat %@"),
               ChartCursorCard.grams(totals.carbs), ChartCursorCard.grams(totals.protein), ChartCursorCard.grams(totals.fat))
    }

    private func foodRow(_ food: FoodItem, keepsOffline: Bool) -> some View {
        Button {
            // A product found online is kept, so it can be reused without a connection.
            if keepsOffline {
                FoodLibrary.save(food)
                custom = FoodLibrary.custom()
            }
            add(food)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(food.name).foregroundStyle(ConstantsAppColors.rowTitleText)
                Text(String(format: ExperimentalTexts.text("food.per100", "per 100 g: carbs %@ · protein %@ · fat %@"),
                            ChartCursorCard.grams(food.carbsPer100), ChartCursorCard.grams(food.proteinPer100), ChartCursorCard.grams(food.fatPer100)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func add(_ food: FoodItem) {
        meal.append(MealIngredient(food: food, grams: FoodLibrary.defaultGrams(for: food, recent: recent)))
    }

    @MainActor
    private func searchOnline() async {
        isSearchingOnline = true
        message = nil
        defer { isSearchingOnline = false }
        do {
            online = try await OpenFoodFacts.search(query)
            if online.isEmpty { message = ExperimentalTexts.text("food.notFound", "Nothing found in Open Food Facts.") }
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func lookUp(barcode: String) async {
        message = nil
        // A product scanned before is reused offline.
        if let known = custom.first(where: { $0.key == OpenFoodFacts.keyPrefix + barcode }) {
            add(known)
            return
        }
        do {
            if let food = try await OpenFoodFacts.product(barcode: barcode) {
                FoodLibrary.save(food)
                custom = FoodLibrary.custom()
                add(food)
            } else {
                message = String(format: ExperimentalTexts.text("food.barcodeNotFound", "Barcode %@ is not in Open Food Facts, or has no carbohydrate value."), barcode)
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

/// One ingredient of the meal: its name, its amount in grams and the portion shortcuts.
private struct FoodIngredientRow: View {
    @Binding var ingredient: MealIngredient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ingredient.food.name)
                Spacer()
                TextField("0", value: $ingredient.grams, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text(Texts_TreatmentsView.carbsUnit).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(ingredient.food.portions, id: \.self) { portion in
                    Button("+1 " + portion.title) { ingredient.grams += portion.grams }
                        .buttonStyle(.bordered).font(.caption)
                }
                Spacer()
                Text(String(format: ExperimentalTexts.text("food.carbs", "carbs %@"), ChartCursorCard.grams(ingredient.food.carbs(grams: ingredient.grams))))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A food of your own, from a nutrition label: values per 100 g.
struct FoodEditorView: View {
    let onSave: (FoodItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var carbs: Double?
    @State private var protein: Double?
    @State private var fat: Double?
    @State private var portion: Double?

    init(name: String = "", onSave: @escaping (FoodItem) -> Void) {
        self.onSave = onSave
        _name = State(initialValue: name)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && FoodEditorView.isValid(carbs: carbs, protein: protein, fat: fat)
    }

    /// Per 100 g: carbs given, nothing negative, and no more than 100 g in total.
    static func isValid(carbs: Double?, protein: Double?, fat: Double?) -> Bool {
        guard let carbs, carbs >= 0, (protein ?? 0) >= 0, (fat ?? 0) >= 0 else { return false }
        return carbs + (protein ?? 0) + (fat ?? 0) <= 100.0001
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(ExperimentalTexts.text("food.editorFooter", "Values per 100 g (or 100 ml), as on the nutrition label. The portion is optional: the weight of one serving."))) {
                    TextField(ExperimentalTexts.text("food.name", "Name"), text: $name)
                    field(Texts_TreatmentsView.carbs, value: $carbs)
                    field(ExperimentalTexts.text("protein", "Protein"), value: $protein)
                    field(ExperimentalTexts.text("fat", "Fat"), value: $fat)
                    field(ExperimentalTexts.text("food.portion", "Portion"), value: $portion)
                }
            }
            .navigationTitle(ExperimentalTexts.text("food.new", "New food"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Texts_Common.Cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Texts_TreatmentsView.saveTreatment) {
                        onSave(FoodItem(key: "custom:" + UUID().uuidString, name: name.trimmingCharacters(in: .whitespaces),
                                        carbsPer100: carbs ?? 0, proteinPer100: protein ?? 0, fatPer100: fat ?? 0,
                                        portions: portion.flatMap { $0 > 0 ? [FoodPortion(name: "serving", grams: $0)] : nil } ?? [], source: .custom))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private func field(_ title: String, value: Binding<Double?>) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text(Texts_TreatmentsView.carbsUnit).foregroundStyle(.secondary)
            }
        }
    }
}

/// The camera, reading product barcodes (EAN-13, EAN-8, UPC-E).
struct FoodBarcodeScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var didScan = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didScan else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue,
                   let code = OpenFoodFacts.normalizedBarcode(payload) {
                    didScan = true
                    dataScanner.stopScanning()
                    onScan(code)
                    return
                }
            }
        }
    }
}

// MARK: - Staples

extension FoodLibrary {
    static let stapleTable = """
apple|11.4|0.3|0.2|piece:182,cup:109|Apple|Яблуко
banana|20.2|1.1|0.3|piece:118|Banana|Банан
orange|9.3|0.9|0.1|piece:131|Orange|Апельсин
mandarin|11.5|0.8|0.3|piece:88|Mandarin|Мандарин
pear|12.1|0.4|0.1|piece:178|Pear|Груша
grapes|17.2|0.7|0.2|cup:151|Grapes|Виноград
strawberries|5.7|0.7|0.3|cup:144,piece:12|Strawberries|Полуниця
blueberries|12.1|0.7|0.3|cup:148|Blueberries|Лохина
raspberries|5.4|1.2|0.7|cup:123|Raspberries|Малина
cherries|13.9|1.1|0.2|cup:138|Cherries|Черешня
peach|8|0.9|0.2|piece:150|Peach|Персик
nectarine|8.9|1.1|0.3|piece:142|Nectarine|Нектарин
plum|10|0.7|0.3|piece:66|Plum|Слива
apricot|9.1|1.4|0.4|piece:35|Apricot|Абрикос
kiwi|11.7|1.1|0.5|piece:69|Kiwi|Ківі
pineapple|11.7|0.5|0.1|cup:165,slice:166|Pineapple|Ананас
mango|13.4|0.8|0.4|cup:165|Mango|Манго
watermelon|7.1|0.6|0.1|cup:152,slice:286|Watermelon|Кавун
melon|7.3|0.8|0.2|cup:160,slice:102|Melon|Диня
grapefruit|9.1|0.8|0.1|piece:246|Grapefruit|Грейпфрут
lemon|6.5|1.1|0.3|piece:58|Lemon|Лимон
pomegranate|14.7|1.7|1.2|piece:282|Pomegranate|Гранат
persimmon|15|0.6|0.2|piece:168|Persimmon|Хурма
fig|16.3|0.8|0.3|piece:50|Fig|Інжир
avocado|1.8|2|14.7|piece:201|Avocado|Авокадо
dates|67|2.5|0.4|piece:7.1|Dates|Фініки
raisins|74.8|3.3|0.2|tbsp:9.1|Raisins|Родзинки
dried_apricots|55.3|3.4|0.5|piece:3.5|Dried apricots|Курага
prunes|56.8|2.2|0.4|piece:9.5|Prunes|Чорнослив
apple_juice|11.1|0.1|0.1|glass:248|Apple juice|Яблучний сік
orange_juice|10.2|0.7|0.2|glass:248|Orange juice|Апельсиновий сік
grape_juice|14.6|0.4|0.1|glass:253|Grape juice|Виноградний сік
tomato_juice|3.1|0.8|0.3|glass:243|Tomato juice|Томатний сік
applesauce|10.2|0.2|0.1|cup:244|Applesauce, unsweetened|Яблучне пюре без цукру
cranberries|8.4|0.5|0.1|cup:100|Cranberries|Журавлина
potato_boiled|18.2|1.7|0.1|piece:167|Potato, boiled|Картопля варена
potato_baked|18.9|2.5|0.1|piece:173|Potato, baked|Картопля запечена
mashed_potatoes|15.4|2|4.2|cup:210|Mashed potatoes|Картопляне пюре
french_fries|26.1|2.7|5.2||French fries, oven-baked|Картопля фрі з духовки
fast_food_fries|37.6|3.4|14.7|serving:117|French fries, fast food|Картопля фрі (фастфуд)
potato_chips|50.7|6.4|34||Potato chips|Чипси картопляні
sweet_potato|17.4|2|0.1|piece:114|Sweet potato, baked|Батат запечений
carrot|6.8|0.9|0.2|piece:61|Carrot|Морква
beetroot|8|1.7|0.2|piece:50|Beetroot, boiled|Буряк варений
tomato|2.7|0.9|0.2|piece:123|Tomato|Помідор
cucumber|3.1|0.7|0.1|piece:301|Cucumber|Огірок
bell_pepper|3.9|1|0.3|piece:119|Bell pepper|Перець солодкий
onion|7.6|1.1|0.1|piece:110|Onion|Цибуля
cabbage|3.3|1.3|0.1|cup:89|Cabbage|Капуста білокачанна
cauliflower|3|1.9|0.3|cup:107|Cauliflower|Цвітна капуста
broccoli|4|2.8|0.4|cup:91|Broccoli|Броколі
zucchini|2.1|1.2|0.3|piece:196|Zucchini|Кабачок
eggplant|2.9|1|0.2|cup:82|Eggplant|Баклажан
pumpkin|3.8|0.7|0.1|cup:245|Pumpkin, boiled|Гарбуз варений
sweet_corn|18.6|3.4|1.5|piece:103,cup:149|Corn on the cob, boiled|Кукурудза варена
canned_corn|12.3|2.3|1.2|cup:164|Sweet corn, canned|Кукурудза консервована
green_peas|10.1|5.4|0.2|cup:160|Green peas, boiled|Зелений горошок варений
green_beans|4.7|1.9|0.3|cup:125|Green beans, boiled|Стручкова квасоля варена
lettuce|1.6|1.4|0.1|cup:36|Lettuce|Салат листовий
spinach|1.4|2.9|0.4|cup:30|Spinach|Шпинат
mushrooms|2.3|3.1|0.3|cup:70|Mushrooms|Печериці
sauerkraut|1.4|0.9|0.1|cup:142|Sauerkraut|Квашена капуста
pickles|1.4|0.5|0.3|piece:135|Pickled cucumber|Огірок солоний
radish|1.8|0.7|0.1|piece:4.5|Radish|Редиска
rice_white_cooked|27.8|2.7|0.3|cup:158|Rice, white, cooked|Рис білий варений
rice_brown_cooked|24|2.7|1|cup:202|Rice, brown, cooked|Рис бурий варений
rice_white_dry|78.7|7.1|0.7|cup:185|Rice, white, dry|Рис білий сухий
buckwheat_cooked|17.2|3.4|0.6|cup:168|Buckwheat, cooked|Гречка варена
buckwheat_dry|64.7|11.7|2.7|cup:164|Buckwheat, dry|Гречка суха
oatmeal_cooked|10.3|2.5|1.5|cup:234|Oatmeal porridge, with water|Вівсяна каша на воді
oats_dry|57.6|13.2|6.5|cup:81|Rolled oats, dry|Вівсяні пластівці сухі
pasta_cooked|29.1|5.8|0.9|cup:151|Pasta, cooked|Макарони варені
pasta_dry|71.5|13|1.5|cup:91|Pasta, dry|Макарони сухі
egg_noodles_cooked|24|4.5|2.1|cup:160|Egg noodles, cooked|Яєчна локшина варена
rice_noodles_cooked|23|1.8|0.2|cup:176|Rice noodles, cooked|Рисова локшина варена
couscous_cooked|21.8|3.8|0.2|cup:157|Couscous, cooked|Кускус готовий
bulgur_cooked|14.1|3.1|0.2|cup:182|Bulgur, cooked|Булгур варений
quinoa_cooked|18.5|4.4|1.9|cup:185|Quinoa, cooked|Кіноа варена
millet_cooked|22.4|3.5|1|cup:174|Millet, cooked|Пшоняна каша
barley_cooked|24.4|2.3|0.4|cup:157|Pearl barley, cooked|Перлова каша
semolina_dry|68.9|12.7|1.1|cup:167|Semolina, dry|Манна крупа
polenta_cooked|13.2|1.2|0.4|cup:233|Corn porridge (polenta)|Кукурудзяна каша
corn_flakes|85.3|5.9|0.9|cup:28|Corn flakes|Кукурудзяні пластівці
granola|45|13.7|24.3|cup:122|Granola|Гранола
wheat_flour|73.6|10.3|1|cup:125|Wheat flour|Борошно пшеничне
rye_flour|63.6|10.9|1.5|cup:102|Rye flour|Борошно житнє
cornstarch|90.4|0.3|0.1|cup:128|Cornstarch|Крохмаль кукурудзяний
popcorn|63.3|12.9|4.5|cup:8|Popcorn|Попкорн
rice_cakes|77.3|8.2|2.8|piece:9|Rice cake|Рисовий хлібець
bread_white|46.7|8.8|3.3|slice:29|Bread, white|Хліб білий
bread_whole_wheat|36.7|12.4|3.5|slice:32|Bread, whole wheat|Хліб цільнозерновий
bread_rye|42.5|8.5|3.3|slice:32|Bread, rye|Хліб житній
baguette|49.7|10.8|2.4||Baguette|Багет
bread_roll|50|10.9|6.5|piece:28|Bread roll|Булочка
pita|53.5|9.1|1.2|piece:60|Pita bread|Піта
tortilla_flour|45.9|8.2|8|piece:48|Tortilla, wheat|Тортилья пшенична
tortilla_corn|38.3|5.7|2.9|piece:24|Tortilla, corn|Тортилья кукурудзяна
bagel|50.8|10.6|1.3|piece:99|Bagel|Бейгл
croissant|43.2|8.2|21|piece:57|Croissant|Круасан
crispbread|65.7|7.9|1.3|piece:10|Rye crispbread|Хлібці житні
crackers|71.2|9.5|8.6|piece:3|Crackers|Крекери
pancakes|40.8|5.9|4.7|piece:38|Pancakes|Оладки
waffles|40.8|6.5|9.7|piece:35|Waffles|Вафлі м’які
muffin|51.9|4.5|16.1|piece:113|Muffin, blueberry|Мафін з чорницею
doughnut|45.8|6.1|22.7|piece:60|Doughnut, glazed|Пончик у глазурі
butter_cookies|68.1|6.1|18.8|piece:5|Butter cookies|Печиво вершкове
choc_chip_cookies|63.4|5.1|24.7|piece:12.9|Chocolate chip cookies|Печиво з шоколадною крихтою
gingerbread|74.7|5.6|9.8|piece:7|Ginger snaps|Імбирне печиво
oatmeal_cookies|65.9|6.2|18.1|piece:25|Oatmeal cookies|Вівсяне печиво
sponge_cake|60.5|5.4|2.7|piece:38|Sponge cake|Бісквіт
cheesecake|25.1|5.5|22.5|piece:125|Cheesecake|Чизкейк
apple_pie|32.4|1.9|11|piece:125|Apple pie|Яблучний пиріг
brownie|61.8|4.8|16.3|piece:56|Brownie|Брауні
cinnamon_roll|48.5|6.2|16.4|piece:60|Cinnamon roll|Булочка з корицею
pretzels|77|10|2.9||Pretzels, hard|Крендлики солоні
hamburger_bun|48.3|9.8|3.9|piece:44|Burger bun|Булочка для бургера
chocolate_cake|50.6|3.5|20.1|piece:138|Chocolate cake|Шоколадний торт
milk_whole|4.8|3.1|3.2|glass:244|Milk, whole|Молоко 3,2%
milk_lowfat|4.8|3.3|2|glass:244|Milk, 2%|Молоко 2%
kefir|4.8|3.8|1|glass:243|Kefir|Кефір
yogurt_plain|4.7|3.5|3.2|cup:245|Yogurt, plain|Йогурт натуральний
yogurt_fruit|19.1|4.4|1.1|cup:245|Yogurt, fruit|Йогурт фруктовий
greek_yogurt|4|9|5||Greek yogurt|Йогурт грецький
sour_cream|4.6|2.4|19.4|tbsp:12|Sour cream|Сметана 20%
cream|2.8|2.8|36.1|tbsp:15|Cream, heavy|Вершки 35%
butter|0.1|0.8|81.1|tbsp:14.2|Butter|Масло вершкове
cottage_cheese|3.4|11.1|4.3|cup:225|Cottage cheese|Сир кисломолочний
cheese_hard|3.4|22.9|33.3|slice:28|Cheese, hard|Сир твердий
mozzarella|2.4|22.2|22.1|slice:28.3|Mozzarella|Моцарела
feta|3.9|14.2|21.5|cup:150|Feta|Фета
cream_cheese|5.5|6.2|34.4|tbsp:14.5|Cream cheese|Сир вершковий
ice_cream|22.9|3.5|11|cup:132|Ice cream, vanilla|Морозиво пломбір
condensed_milk|54.4|7.9|8.7|tbsp:19.1|Condensed milk, sweetened|Згущене молоко
cocoa_drink|9.7|3.5|2.3|glass:250|Hot cocoa with milk|Какао на молоці
soy_milk|5.7|3.3|1.8|glass:243|Soy milk|Соєве молоко
almond_milk|1.1|0.4|1|glass:262|Almond milk, unsweetened|Мигдалеве молоко без цукру
buttermilk|4.8|3.3|1.1|glass:245|Buttermilk|Маслянка
egg|1.1|12.6|10.6|piece:50|Egg, boiled|Яйце варене
omelet|0.6|10.6|11.7|piece:61|Omelet|Омлет
fried_egg|0.8|13.6|14.8|piece:46|Egg, fried|Яєчня
chicken_breast|0|30.5|3.2||Chicken breast, grilled|Куряча грудка на грилі
chicken_thigh|0|24.8|8.2||Chicken thigh, roasted|Куряче стегно запечене
turkey|0|29.1|3.8||Turkey, roasted|Індичка запечена
beef_ground|0|24.6|14||Ground beef, cooked|Яловичий фарш смажений
beef_steak|0|27|14.2||Beef steak|Стейк яловичий
pork_chop|0|25.6|11.1||Pork chop|Свиняча відбивна
bacon|1.7|33.9|35.1|slice:11.5|Bacon, fried|Бекон смажений
ham|2.3|16.6|8.8|slice:28|Ham|Шинка
frankfurter|3|11.7|28.1|piece:49|Frankfurter sausage|Сосиска
salami|2.4|21.9|25.9|slice:12.3|Salami|Салямі
salmon|0|22.1|12.3||Salmon, cooked|Лосось запечений
tuna_canned|0|19.4|1||Tuna, canned in water|Тунець консервований
cod|0|22.8|0.9||Cod, cooked|Тріска запечена
herring|9.6|14.2|18||Herring, pickled|Оселедець маринований
shrimp|1.5|22.8|1.7||Shrimp, boiled|Креветки варені
fish_sticks|20.2|11|16.2|piece:28|Fish sticks|Рибні палички
chicken_nuggets|14|15.9|20.4|piece:16|Chicken nuggets|Курячі нагетси
tofu|1.6|8.1|4.8||Tofu|Тофу
lentils_cooked|12.2|9|0.4|cup:198|Lentils, cooked|Сочевиця варена
chickpeas_cooked|19.8|8.9|2.6|cup:164|Chickpeas, cooked|Нут варений
kidney_beans_cooked|15.4|8.7|0.5|cup:177|Red beans, cooked|Квасоля червона варена
white_beans_cooked|18.8|9.7|0.3|cup:179|White beans, cooked|Квасоля біла варена
baked_beans|17|4.8|0.4|cup:254|Baked beans in tomato sauce|Квасоля в томатному соусі
hummus|9.5|7.8|17.8|tbsp:15|Hummus|Хумус
peanuts|12.9|24.4|49.7||Peanuts, roasted|Арахіс смажений
almonds|9.1|21.1|49.9||Almonds|Мигдаль
walnuts|7|15.2|65.2||Walnuts|Волоські горіхи
hazelnuts|7|14.9|60.8||Hazelnuts|Фундук
cashews|29.7|15.3|46.4||Cashews|Кеш’ю
pistachios|17.2|21.1|45.8||Pistachios|Фісташки
sunflower_seeds|11.4|20.8|51.5||Sunflower seeds|Насіння соняшника
pumpkin_seeds|4.7|30.2|49||Pumpkin seeds|Гарбузове насіння
peanut_butter|17.3|22.2|51.4|tbsp:16|Peanut butter|Арахісова паста
sugar|100|0|0|tsp:4.2,tbsp:12.6|Sugar|Цукор
honey|82.2|0.3|0|tbsp:21,tsp:7|Honey|Мед
jam|67.8|0.4|0.1|tbsp:20|Jam|Варення, джем
maple_syrup|67|0|0.1|tbsp:20|Maple syrup|Кленовий сироп
milk_chocolate|56|7.7|29.7||Milk chocolate|Шоколад молочний
dark_chocolate|35|7.8|42.6||Dark chocolate, 70–85%|Шоколад чорний 70–85%
hazelnut_spread|57|5.4|29.7|tbsp:18.5|Chocolate hazelnut spread|Шоколадно-горіхова паста
hard_candy|98|0|0.2|piece:6|Hard candy|Льодяник
gummies|98.8|0|0|piece:2.2|Gummy candy|Мармелад жувальний
marshmallow|81.2|1.8|0.2|piece:7.2|Marshmallow|Маршмелоу
halva|56|12.5|21.5||Halva|Халва
caramel|77|4.6|8.1|piece:10.1|Caramel candy|Карамель м’яка
snickers|59.2|7.5|23.9|piece:57|Snickers bar|Батончик Snickers
tortilla_chips|62.4|7.1|20.7||Tortilla chips|Кукурудзяні чипси
granola_bar|59.1|10.1|19.8|piece:21|Granola bar|Батончик злаковий
cola|10.4|0|0.2|glass:245.6|Cola|Кола
lemon_soda|10.4|0.1|0|glass:246.4|Lemon-lime soda|Лимонад
energy_drink|10.2|0.5|0|serving:258|Energy drink|Енергетичний напій
sports_drink|6.4|0|0|glass:244|Sports drink|Спортивний напій
beer|3.5|0.5|0|serving:356|Beer|Пиво
wine_red|2.6|0.1|0|serving:147|Red wine|Вино червоне сухе
wine_white|2.6|0.1|0|serving:147|White wine|Вино біле сухе
iced_tea|10.8|0|0.2|glass:271|Iced tea, sweetened|Холодний чай із цукром
coconut_water|4.2|0.2|0|glass:245|Coconut water|Кокосова вода
pizza|31|10.8|10.5|slice:115|Pizza, cheese|Піца з сиром
hamburger|29.8|16.5|12|piece:78|Hamburger|Гамбургер
cheeseburger|26|16.5|14.7|piece:91|Cheeseburger|Чизбургер
fried_rice|31.7|4|3|cup:137|Fried rice|Смажений рис
lasagna|13|6.6|4.4|piece:278|Lasagna with meat|Лазанья з м’ясом
spaghetti_meat_sauce|13.4|5|1||Spaghetti with meat sauce|Спагеті з м’ясним соусом
mac_cheese|11|3.4|2.5|serving:244|Macaroni and cheese|Макарони з сиром
burrito|27|7.3|6|piece:185|Burrito, beans and cheese|Буріто з квасолею і сиром
taco|16|8.9|12.7|piece:69|Taco with beef|Тако з яловичиною
pierogi|28.7|5.3|6.1|piece:38|Dumplings, potato or cheese|Вареники з картоплею або сиром
ravioli|12.3|2.5|1.4|cup:242|Ravioli, cheese, canned|Равіолі з сиром
chicken_soup|2.5|1.2|0.8|cup:248|Chicken noodle soup|Курячий суп із локшиною
tomato_soup|7|0.7|0.2|cup:248|Tomato soup|Томатний суп
pea_soup|10.2|4.1|1.7|cup:253|Pea soup with ham|Гороховий суп із шинкою
potato_salad|9.9|2.7|8.2|cup:250|Potato salad|Картопляний салат
coleslaw|13|0.9|9.9|cup:191|Coleslaw|Салат коулслоу
french_toast|31|7.4|6.1|slice:59|French toast|Грінки солодкі
egg_roll|29.4|6|7|piece:68|Spring roll, vegetable|Спринг-рол овочевий
sushi_rice|20.1|2|0.2|cup:174|Sticky rice, cooked|Рис клейкий варений
ketchup|27.1|1|0.1|tbsp:17|Ketchup|Кетчуп
mayonnaise|0.6|1|74.8|tbsp:13.8|Mayonnaise|Майонез
mustard|1.8|3.7|3.3|tsp:5|Mustard|Гірчиця
soy_sauce|4.1|8.1|0.6|tbsp:16|Soy sauce|Соєвий соус
bbq_sauce|39.9|0.8|0.6|tbsp:17|Barbecue sauce|Соус барбекю
pasta_sauce|5.6|1.4|1.6|cup:264|Tomato pasta sauce|Томатний соус для пасти
olive_oil|0|0|100|tbsp:13.5|Olive oil|Оливкова олія
sunflower_oil|0|0|100|tbsp:13.6|Sunflower oil|Соняшникова олія
salsa|4.7|1.5|0.2|tbsp:18|Salsa|Сальса
naan|48.2|9.6|5.7|piece:90|Naan bread|Коржик наан
kimchi|0.8|1.1|0.5|cup:150|Kimchi|Кімчі
instant_noodles_dry|57.4|10.2|17.6|piece:81|Instant noodles, dry|Локшина швидкого приготування суха
cheese_gouda|2.2|24.9|27.4||Gouda cheese|Сир гауда
parmesan|3.2|35.8|25||Parmesan|Пармезан
bratwurst|2.9|13.7|29.2|piece:85|Bratwurst|Ковбаска смажена
mackerel|0|23.9|17.8||Mackerel, cooked|Скумбрія запечена
"""
}
