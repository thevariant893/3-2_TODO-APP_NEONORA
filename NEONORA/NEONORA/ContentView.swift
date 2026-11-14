import SwiftUI
import Combine
import FirebaseAuth
import FirebaseFirestore

// MARK: - Task model

struct NeonoraTask: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var category: String
    var dueDate: Date
    var priority: NeonoraPriority
    var isCompleted: Bool = false

    var firestoreData: [String: Any] {
        [
            "title": title,
            "category": category,
            "dueDate": Timestamp(date: dueDate),
            "priority": priority.rawValue,
            "isCompleted": isCompleted
        ]
    }

    init(
        id: UUID = UUID(),
        title: String,
        category: String,
        dueDate: Date,
        priority: NeonoraPriority,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.dueDate = dueDate
        self.priority = priority
        self.isCompleted = isCompleted
    }

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        guard
            let title = data["title"] as? String,
            let category = data["category"] as? String,
            let timestamp = data["dueDate"] as? Timestamp,
            let priorityValue = data["priority"] as? String,
            let priority = NeonoraPriority(rawValue: priorityValue)
        else {
            return nil
        }

        self.id = UUID(uuidString: document.documentID) ?? UUID()
        self.title = title
        self.category = category
        self.dueDate = timestamp.dateValue()
        self.priority = priority
        self.isCompleted = data["isCompleted"] as? Bool ?? false
    }
}

enum NeonoraPriority: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var color: Color {
        switch self {
        case .low: return .neonMint
        case .medium: return .neonAmber
        case .high: return .neonPink
        }
    }
}

enum NeonoraFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .active: return "In progress"
        case .completed: return "Completed"
        }
    }
}

// MARK: - Authentication state

final class NeonoraAuthSession: ObservableObject {
    @Published var user: FirebaseAuth.User?
    @Published var isChecking = true

    private var listener: AuthStateDidChangeListenerHandle?

    init() {
        user = Auth.auth().currentUser
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            DispatchQueue.main.async {
                self?.user = user
                self?.isChecking = false
            }
        }
    }

    deinit {
        if let listener {
            Auth.auth().removeStateDidChangeListener(listener)
        }
    }
}

// MARK: - Firestore task store

final class NeonoraTaskStore: ObservableObject {
    @Published var tasks: [NeonoraTask] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let database = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var currentUserID: String?

    private func tasksCollection(for userID: String) -> CollectionReference {
        database.collection("users").document(userID).collection("tasks")
    }

    func startListening(userID: String) {
        guard currentUserID != userID || listener == nil else { return }

        listener?.remove()
        currentUserID = userID
        tasks = []
        isLoading = true

        listener = tasksCollection(for: userID)
            .order(by: "dueDate")
            .addSnapshotListener { [weak self] snapshot, error in
                DispatchQueue.main.async {
                    guard let self else { return }

                    if let error {
                        self.errorMessage = "Couldn't load your tasks: \(error.localizedDescription)"
                        self.isLoading = false
                        return
                    }

                    self.tasks = snapshot?.documents.compactMap {
                        NeonoraTask(document: $0)
                    } ?? []
                    self.isLoading = false
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        currentUserID = nil
        tasks = []
        isLoading = true
    }

    func add(_ task: NeonoraTask) {
        guard let userID = currentUserID else {
            errorMessage = "Please sign in before adding a task."
            return
        }

        tasksCollection(for: userID)
            .document(task.id.uuidString)
            .setData(task.firestoreData) { [weak self] error in
                if let error {
                    DispatchQueue.main.async {
                        self?.errorMessage = "Couldn't save the task: \(error.localizedDescription)"
                    }
                }
            }
    }

    func setCompleted(_ task: NeonoraTask, to value: Bool) {
        guard let userID = currentUserID else { return }

        tasksCollection(for: userID)
            .document(task.id.uuidString)
            .updateData(["isCompleted": value]) { [weak self] error in
                if let error {
                    DispatchQueue.main.async {
                        self?.errorMessage = "Couldn't update the task: \(error.localizedDescription)"
                    }
                }
            }
    }

    func delete(_ task: NeonoraTask) {
        guard let userID = currentUserID else { return }

        tasksCollection(for: userID)
            .document(task.id.uuidString)
            .delete { [weak self] error in
                if let error {
                    DispatchQueue.main.async {
                        self?.errorMessage = "Couldn't delete the task: \(error.localizedDescription)"
                    }
                }
            }
    }
}

// MARK: - Main app screen

struct ContentView: View {
    @StateObject private var auth = NeonoraAuthSession()
    @StateObject private var store = NeonoraTaskStore()

    @State private var selectedFilter: NeonoraFilter = .all
    @State private var searchText = ""
    @State private var showingAddTask = false

    private var completedCount: Int {
        store.tasks.filter(\.isCompleted).count
    }

    private var activeCount: Int {
        store.tasks.count - completedCount
    }

    private var progress: Double {
        guard !store.tasks.isEmpty else { return 0 }
        return Double(completedCount) / Double(store.tasks.count)
    }

    private var filteredTasks: [NeonoraTask] {
        let filteredByStatus = store.tasks.filter { task in
            switch selectedFilter {
            case .all: return true
            case .active: return !task.isCompleted
            case .completed: return task.isCompleted
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return filteredByStatus }

        return filteredByStatus.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.category.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if auth.isChecking {
                ZStack {
                    Color.neonBackground.ignoresSafeArea()
                    VStack(spacing: 14) {
                        NeonoraMark(size: 58)
                        ProgressView("Connecting to your workspace…")
                            .tint(.neonCyan)
                            .foregroundStyle(Color.neonMuted)
                    }
                }
            } else if let user = auth.user {
                dashboard(for: user)
            } else {
                NeonoraAuthView()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let userID = auth.user?.uid {
                store.startListening(userID: userID)
            }
        }
        .onChange(of: auth.user?.uid) { _, newUserID in
            store.stopListening()
            if let newUserID {
                store.startListening(userID: newUserID)
            }
        }
        .alert(
            "Connection notice",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("Got it", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Please try again.")
        }
    }

    private func dashboard(for user: FirebaseAuth.User) -> some View {
        ZStack {
            NeonoraBackdrop()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 23) {
                    header(for: user)
                    progressPanel
                    quickStats
                    taskSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 30)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                showingAddTask = true
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .black))
                    Text("New task")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text("CREATE")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(Color.neonBackground)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(NeonoraGradients.action, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .shadow(color: Color.neonViolet.opacity(0.27), radius: 17, x: 0, y: 7)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 9)
            .background(.ultraThinMaterial)
        }
        .sheet(isPresented: $showingAddTask) {
            NeonoraAddTaskView { task in
                store.add(task)
                selectedFilter = .all
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: Header

    private func header(for user: FirebaseAuth.User) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 12) {
                NeonoraMark(size: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text("NEONORA")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(Color.neonText)
                    Text("DAILY CONTROL CENTER")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(Color.neonMuted)
                }
            }

            Spacer(minLength: 4)

            Menu {
                if let email = user.email {
                    Text(email)
                }
                Button(role: .destructive) {
                    do {
                        try Auth.auth().signOut()
                    } catch {
                        store.errorMessage = "Couldn't sign out: \(error.localizedDescription)"
                    }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.neonCyan)
                    .frame(width: 43, height: 43)
                    .background(Color.neonSurface, in: Circle())
                    .overlay(Circle().stroke(Color.neonLine, lineWidth: 1))
            }
        }
    }

    // MARK: Progress panel

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color.neonMint)
                            .frame(width: 6, height: 6)
                            .shadow(color: Color.neonMint.opacity(0.9), radius: 6)
                        Text("SYSTEM STATUS / ACTIVE")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(Color.neonMint)
                    }

                    Text("Move with\nintention.")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.neonText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(completedCount) of \(store.tasks.count) objectives completed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.neonMuted)
                }

                Spacer(minLength: 0)

                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.09), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            AngularGradient(
                                colors: [.neonCyan, .neonViolet, .neonPink],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .shadow(color: Color.neonCyan.opacity(0.55), radius: 7)
                    VStack(spacing: 1) {
                        Text("\(Int(progress * 100))")
                            .font(.system(size: 18, weight: .black, design: .rounded))
                        Text("PCT")
                            .font(.system(size: 7, weight: .heavy, design: .rounded))
                            .tracking(1)
                            .foregroundStyle(Color.neonMuted)
                    }
                    .foregroundStyle(Color.neonText)
                }
                .frame(width: 82, height: 82)
                .padding(.top, 8)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule()
                        .fill(NeonoraGradients.action)
                        .frame(width: max(0, geometry.size.width * progress))
                        .shadow(color: Color.neonCyan.opacity(0.45), radius: 7)
                }
            }
            .frame(height: 7)

            HStack {
                Text(activeCount == 0 ? "All clear. Take a breath." : "One objective at a time.")
                Spacer()
                Text("\(activeCount) LEFT")
                    .fontWeight(.heavy)
                    .tracking(0.8)
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Color.neonMuted)
        }
        .padding(20)
        .background {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .fill(NeonoraGradients.panel)
                Circle()
                    .stroke(Color.neonCyan.opacity(0.10), lineWidth: 26)
                    .frame(width: 175, height: 175)
                    .offset(x: 76, y: -105)
                Circle()
                    .fill(Color.neonViolet.opacity(0.12))
                    .frame(width: 90, height: 90)
                    .blur(radius: 24)
                    .offset(x: -8, y: 125)
            }
            .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: Color.neonViolet.opacity(0.13), radius: 22, x: 0, y: 10)
    }

    // MARK: Quick stats

    private var quickStats: some View {
        HStack(spacing: 11) {
            statCard(
                title: "IN PROGRESS",
                value: activeCount,
                symbol: "bolt.fill",
                gradient: NeonoraGradients.cyan
            )
            statCard(
                title: "COMPLETED",
                value: completedCount,
                symbol: "checkmark",
                gradient: NeonoraGradients.violet
            )
        }
    }

    private func statCard(title: String, value: Int, symbol: String, gradient: LinearGradient) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color.neonBackground)
                .frame(width: 35, height: 35)
                .background(gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("\(value)")
                    .font(.system(size: 23, weight: .black, design: .rounded))
                    .foregroundStyle(Color.neonText)
                Text(title)
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(Color.neonMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.neonSurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.neonLine, lineWidth: 1))
    }

    // MARK: Task list

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your objectives")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.neonText)
                    Text("Keep your next move in sight.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.neonMuted)
                }

                Spacer()

                Text("\(filteredTasks.count) ITEMS")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(Color.neonCyan)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.neonCyan)
                TextField("Search tasks or categories…", text: $searchText)
                    .font(.system(size: 13))
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 14)
            .background(Color.neonSurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.neonLine, lineWidth: 1))

            HStack(spacing: 7) {
                ForEach(NeonoraFilter.allCases) { filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedFilter = filter
                        }
                    } label: {
                        Text(filter.title)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(selectedFilter == filter ? Color.neonBackground : Color.neonMuted)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background {
                                Capsule()
                                    .fill(selectedFilter == filter ? NeonoraGradients.action : LinearGradient(colors: [Color.neonSurface, Color.neonSurface], startPoint: .leading, endPoint: .trailing))
                            }
                            .overlay(Capsule().stroke(selectedFilter == filter ? Color.clear : Color.neonLine, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            if store.isLoading {
                ProgressView()
                    .tint(.neonCyan)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else if filteredTasks.isEmpty {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(filteredTasks) { task in
                        NeonoraTaskRow(
                            task: task,
                            onToggle: { store.setCompleted(task, to: !task.isCompleted) },
                            onDelete: { store.delete(task) }
                        )
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: searchText.isEmpty ? "sparkles.rectangle.stack" : "magnifyingglass")
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(Color.neonCyan)
            Text(searchText.isEmpty ? "No objectives yet" : "No signal found")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.neonText)
            Text(searchText.isEmpty ? "Create your first task to get moving." : "Try another keyword or filter.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.neonMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(Color.neonSurface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(Color.neonLine, lineWidth: 1))
    }
}

// MARK: - Task row

struct NeonoraTaskRow: View {
    let task: NeonoraTask
    let onToggle: () -> Void
    let onDelete: () -> Void

    private var categorySymbol: String {
        switch task.category {
        case "Study": return "book.closed.fill"
        case "Work": return "briefcase.fill"
        case "Personal": return "person.fill"
        case "Health": return "heart.fill"
        case "Home": return "house.fill"
        default: return "sparkle"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            task.isCompleted
                                ? AnyShapeStyle(NeonoraGradients.action)
                                : AnyShapeStyle(Color.neonRaised)
                        )
                    Image(systemName: task.isCompleted ? "checkmark" : categorySymbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(task.isCompleted ? Color.neonBackground : Color.neonCyan)
                }
                .frame(width: 42, height: 42)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.neonLine, lineWidth: task.isCompleted ? 0 : 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark as in progress" : "Mark as completed")

            VStack(alignment: .leading, spacing: 7) {
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(task.isCompleted ? Color.neonMuted : Color.neonText)
                    .strikethrough(task.isCompleted)
                    .lineLimit(2)

                HStack(spacing: 7) {
                    Text(task.category.uppercased())
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(Color.neonCyan)
                    Circle().fill(Color.neonMuted.opacity(0.55)).frame(width: 3, height: 3)
                    Text(task.dueDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.neonMuted)
                }
            }

            Spacer(minLength: 2)

            VStack(alignment: .trailing, spacing: 6) {
                Circle()
                    .fill(task.priority.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: task.priority.color.opacity(0.8), radius: 5)
                Text(task.priority.title.uppercased())
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(task.priority.color)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 13)
        .background(Color.neonSurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.neonLine, lineWidth: 1))
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete task", systemImage: "trash")
            }
        }
    }
}

// MARK: - Add task sheet

struct NeonoraAddTaskView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var category = "Study"
    @State private var priority: NeonoraPriority = .medium
    @State private var dueDate = Date()

    let onSave: (NeonoraTask) -> Void

    private let categories = ["Study", "Work", "Personal", "Health", "Home"]

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NeonoraBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("NEW OBJECTIVE / 001")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .tracking(1.7)
                                .foregroundStyle(Color.neonCyan)
                            Text("What’s the next move?")
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.neonText)
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            fieldLabel("TASK NAME")
                            TextField("e.g. Finish the project prototype", text: $title)
                                .font(.system(size: 14))
                                .padding(16)
                                .background(Color.neonSurface, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.neonLine, lineWidth: 1))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            fieldLabel("CATEGORY")
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                                ForEach(categories, id: \.self) { option in
                                    Button {
                                        category = option
                                    } label: {
                                        HStack(spacing: 7) {
                                            Image(systemName: categorySymbol(option))
                                            Text(option)
                                            Spacer(minLength: 0)
                                            if category == option {
                                                Image(systemName: "checkmark.circle.fill")
                                            }
                                        }
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(category == option ? Color.neonBackground : Color.neonMuted)
                                        .padding(12)
                                        .background {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(category == option ? NeonoraGradients.action : LinearGradient(colors: [Color.neonSurface, Color.neonSurface], startPoint: .leading, endPoint: .trailing))
                                        }
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.neonLine, lineWidth: category == option ? 0 : 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            fieldLabel("PRIORITY LEVEL")
                            HStack(spacing: 8) {
                                ForEach(NeonoraPriority.allCases) { option in
                                    Button {
                                        priority = option
                                    } label: {
                                        Text(option.title)
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(priority == option ? Color.neonBackground : option.color)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(priority == option ? LinearGradient(colors: [option.color, option.color.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing) : LinearGradient(colors: [option.color.opacity(0.10), option.color.opacity(0.10)], startPoint: .leading, endPoint: .trailing), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            fieldLabel("DEADLINE")
                            DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                                .datePickerStyle(.compact)
                                .tint(.neonCyan)
                                .padding(14)
                                .background(Color.neonSurface, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.neonLine, lineWidth: 1))
                        }

                        Button {
                            let task = NeonoraTask(
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                category: category,
                                dueDate: dueDate,
                                priority: priority
                            )
                            onSave(task)
                            dismiss()
                        } label: {
                            HStack {
                                Text("Save objective")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.neonBackground)
                            .padding(.horizontal, 18)
                            .frame(height: 53)
                            .background(NeonoraGradients.action, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: Color.neonViolet.opacity(0.25), radius: 14, y: 6)
                        }
                        .disabled(!canSave)
                        .opacity(canSave ? 1 : 0.48)
                    }
                    .padding(21)
                }
            }
            .navigationTitle("Create task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Color.neonMuted)
                }
            }
        }
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1.3)
            .foregroundStyle(Color.neonMuted)
    }

    private func categorySymbol(_ value: String) -> String {
        switch value {
        case "Study": return "book.closed"
        case "Work": return "briefcase"
        case "Personal": return "person"
        case "Health": return "heart"
        case "Home": return "house"
        default: return "sparkle"
        }
    }
}

// MARK: - Email and password authentication

struct NeonoraAuthView: View {
    @State private var isCreatingAccount = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var alertMessage = ""
    @State private var showingAlert = false

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        let validEmail = trimmedEmail.contains("@") && trimmedEmail.contains(".")
        let validPassword = password.count >= 6
        let matchingPasswords = !isCreatingAccount || password == confirmPassword
        return validEmail && validPassword && matchingPasswords && !isWorking
    }

    var body: some View {
        ZStack {
            NeonoraBackdrop()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 25) {
                    VStack(spacing: 12) {
                        NeonoraMark(size: 76)
                            .shadow(color: Color.neonCyan.opacity(0.23), radius: 19, y: 5)

                        Text("NEONORA")
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .tracking(3.5)
                            .foregroundStyle(Color.neonText)

                        Text("A CLEARER SIGNAL FOR YOUR NEXT MOVE")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .tracking(1.5)
                            .foregroundStyle(Color.neonMuted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 50)

                    VStack(alignment: .leading, spacing: 17) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(isCreatingAccount ? "Create your account" : "Welcome back")
                                .font(.system(size: 23, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.neonText)
                            Text(isCreatingAccount ? "Build your own space and keep every objective in sync." : "Sign in to reconnect with your objectives.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.neonMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("EMAIL ADDRESS")
                            HStack(spacing: 11) {
                                Image(systemName: "envelope")
                                    .foregroundStyle(Color.neonCyan)
                                TextField("name@example.com", text: $email)
                                    .keyboardType(.emailAddress)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .textContentType(.emailAddress)
                            }
                            .padding(15)
                            .background(Color.neonBackground, in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.neonLine, lineWidth: 1))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("PASSWORD")
                            HStack(spacing: 11) {
                                Image(systemName: "lock")
                                    .foregroundStyle(Color.neonViolet)
                                SecureField("At least 6 characters", text: $password)
                                    .textContentType(isCreatingAccount ? .newPassword : .password)
                            }
                            .padding(15)
                            .background(Color.neonBackground, in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.neonLine, lineWidth: 1))
                        }

                        if isCreatingAccount {
                            VStack(alignment: .leading, spacing: 8) {
                                fieldLabel("CONFIRM PASSWORD")
                                HStack(spacing: 11) {
                                    Image(systemName: "lock.shield")
                                        .foregroundStyle(Color.neonPink)
                                    SecureField("Enter password again", text: $confirmPassword)
                                        .textContentType(.newPassword)
                                }
                                .padding(15)
                                .background(Color.neonBackground, in: RoundedRectangle(cornerRadius: 13))
                                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.neonLine, lineWidth: 1))
                            }
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.neonPink)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button(action: submit) {
                            HStack(spacing: 10) {
                                if isWorking {
                                    ProgressView().tint(Color.neonBackground)
                                } else {
                                    Text(isCreatingAccount ? "Create account" : "Sign in")
                                    Image(systemName: "arrow.up.right")
                                }
                            }
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.neonBackground)
                            .frame(maxWidth: .infinity)
                            .frame(height: 53)
                            .background(NeonoraGradients.action, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .shadow(color: Color.neonViolet.opacity(0.24), radius: 14, y: 6)
                        }
                        .disabled(!canSubmit)
                        .opacity(canSubmit ? 1 : 0.5)

                        if !isCreatingAccount {
                            Button("Forgot password?") {
                                sendPasswordReset()
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.neonCyan)
                            .frame(maxWidth: .infinity)
                            .disabled(trimmedEmail.isEmpty || isWorking)
                        }
                    }
                    .padding(21)
                    .background(Color.neonSurface.opacity(0.96), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.neonLine, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.22), radius: 22, y: 10)

                    HStack(spacing: 5) {
                        Text(isCreatingAccount ? "Already registered?" : "New to Neonora?")
                            .foregroundStyle(Color.neonMuted)
                        Button(isCreatingAccount ? "Sign in" : "Create account") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isCreatingAccount.toggle()
                                errorMessage = nil
                                password = ""
                                confirmPassword = ""
                            }
                        }
                        .fontWeight(.bold)
                        .foregroundStyle(Color.neonCyan)
                    }
                    .font(.system(size: 12))
                    .padding(.bottom, 30)
                }
                .padding(.horizontal, 21)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
        }
        .alert("Password reset", isPresented: $showingAlert) {
            Button("Okay", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1.3)
            .foregroundStyle(Color.neonMuted)
    }

    private func submit() {
        errorMessage = nil
        isWorking = true

        if isCreatingAccount {
            Auth.auth().createUser(withEmail: trimmedEmail, password: password) { _, error in
                DispatchQueue.main.async {
                    isWorking = false
                    if let error {
                        errorMessage = readableAuthError(error)
                    }
                }
            }
        } else {
            Auth.auth().signIn(withEmail: trimmedEmail, password: password) { _, error in
                DispatchQueue.main.async {
                    isWorking = false
                    if let error {
                        errorMessage = readableAuthError(error)
                    }
                }
            }
        }
    }

    private func sendPasswordReset() {
        guard !trimmedEmail.isEmpty else { return }
        isWorking = true

        Auth.auth().sendPasswordReset(withEmail: trimmedEmail) { error in
            DispatchQueue.main.async {
                isWorking = false
                if let error {
                    alertMessage = readableAuthError(error)
                } else {
                    alertMessage = "If an account exists for this email, Firebase will send a password reset link. Check your inbox."
                }
                showingAlert = true
            }
        }
    }

    private func readableAuthError(_ error: Error) -> String {
        let nsError = error as NSError
        if let code = AuthErrorCode(rawValue: nsError.code) {
            switch code {
            case .invalidEmail:
                return "Please enter a valid email address."
            case .emailAlreadyInUse:
                return "An account already exists with this email. Try signing in."
            case .weakPassword:
                return "Choose a stronger password with at least 6 characters."
            case .wrongPassword, .invalidCredential:
                return "The email or password is incorrect. Please try again."
            case .userNotFound:
                return "No account was found. Create an account first."
            case .networkError:
                return "Network error. Check your internet connection."
            case .operationNotAllowed:
                return "Email/Password sign-in is disabled in Firebase Console."
            default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Neonora visual components

private struct NeonoraMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(NeonoraGradients.mark)
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.42, weight: .black))
                .foregroundStyle(Color.neonBackground)
                .shadow(color: Color.white.opacity(0.26), radius: 5)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.neonCyan.opacity(0.16), radius: 12, y: 4)
    }
}

private struct NeonoraBackdrop: View {
    var body: some View {
        ZStack {
            Color.neonBackground
            Circle()
                .fill(Color.neonViolet.opacity(0.15))
                .frame(width: 270, height: 270)
                .blur(radius: 85)
                .offset(x: 165, y: -320)
            Circle()
                .fill(Color.neonCyan.opacity(0.10))
                .frame(width: 230, height: 230)
                .blur(radius: 80)
                .offset(x: -165, y: 300)
            LinearGradient(
                colors: [Color.clear, Color.neonBackground.opacity(0.22), Color.neonBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private enum NeonoraGradients {
    static let action = LinearGradient(
        colors: [.neonCyan, .neonViolet],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let panel = LinearGradient(
        colors: [Color(red: 0.11, green: 0.15, blue: 0.27), Color(red: 0.15, green: 0.13, blue: 0.29)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let mark = LinearGradient(
        colors: [.neonCyan, .neonViolet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cyan = LinearGradient(
        colors: [.neonCyan, Color(red: 0.34, green: 0.72, blue: 1.0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let violet = LinearGradient(
        colors: [.neonViolet, .neonPink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Neonora color palette

extension Color {
    static let neonBackground = Color(red: 0.035, green: 0.047, blue: 0.090)
    static let neonSurface = Color(red: 0.075, green: 0.094, blue: 0.160)
    static let neonRaised = Color(red: 0.105, green: 0.132, blue: 0.215)
    static let neonText = Color(red: 0.93, green: 0.96, blue: 1.00)
    static let neonMuted = Color(red: 0.57, green: 0.63, blue: 0.75)
    static let neonLine = Color(red: 0.19, green: 0.23, blue: 0.34)
    static let neonCyan = Color(red: 0.30, green: 0.88, blue: 0.98)
    static let neonViolet = Color(red: 0.60, green: 0.46, blue: 1.00)
    static let neonPink = Color(red: 1.00, green: 0.39, blue: 0.70)
    static let neonMint = Color(red: 0.36, green: 0.92, blue: 0.72)
    static let neonAmber = Color(red: 1.00, green: 0.74, blue: 0.36)
}

#Preview {
    ContentView()
}
