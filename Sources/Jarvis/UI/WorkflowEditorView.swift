import SwiftUI
import AppKit

struct WorkflowSettingsTab: View {
    @Bindable var coordinator: Coordinator
    var body: some View {
        ScrollView { WorkflowLibraryView(library: Binding(get: { coordinator.settings.settings.workflowLibrary }, set: { coordinator.settings.settings.workflowLibrary = $0 })).padding(24) }
    }
}

struct WorkflowEditorView: View {
    @Binding var definition: WorkflowDefinition
    @Environment(\.dismiss) private var dismiss
    @State private var draft = WorkflowDefinition.standard
    @State private var selected = "plan"
    @State private var connections = WorkflowConnectionInteraction()
    @State private var camera = WorkflowCanvasCamera()
    @State private var showingActions = false
    var library: Binding<WorkflowLibrary>?
    init(definition: Binding<WorkflowDefinition>, library: Binding<WorkflowLibrary>? = nil, selectedNode: String? = nil) {
        self.library = library
        _definition = definition
        _draft = State(initialValue: definition.wrappedValue)
        _selected = State(initialValue: selectedNode ?? definition.wrappedValue.entry)
    }
    private var selectionIndex: Int? { draft.nodes.firstIndex { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Editor workflow").font(.title2.bold())
                    Text("Seleziona una card per configurarla. Apri Azioni per scegliere una fase o aggiungere un’azione.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Azioni", systemImage: "square.grid.2x2") { showingActions = true }
            }
            HStack {
                TextField("Nome workflow", text: $draft.name).frame(width: 230)
                Picker("Tipo", selection: Binding(get: { draft.executionMode }, set: { draft.mode = $0 })) {
                    ForEach(WorkflowMode.allCases) { Text($0.label).tag($0) }
                }.frame(width: 250)
                if !draft.nodes.isEmpty {
                    Picker("Inizio", selection: $draft.entry) {
                        ForEach(draft.nodes) { Text($0.title).tag($0.id) }
                    }.frame(maxWidth: 280)
                }
                Spacer()
            }
            if draft.hasPlan {
                Toggle("Richiedi approvazione del Piano", isOn: $draft.requiresPlanApproval)
            }
            HStack(alignment: .top, spacing: 14) {
                WorkflowCanvasView(definition: $draft, selected: $selected, connections: connections, camera: camera)
                    .overlay {
                        if draft.nodes.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 28)).foregroundStyle(.secondary)
                                Text("Workflow vuoto").font(.headline)
                                Text("Aggiungi un’azione AI, un comando o una fase. Il primo nodo sarà l’inizio del percorso.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 330)
                                Button("Aggiungi prima azione", systemImage: "plus") { showingActions = true }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                if let index = selectionIndex {
                    ScrollView { inspector(index) }.frame(width: 250)
                }
            }.frame(maxHeight: .infinity)

            Text(connections.message.isEmpty ? "Ingresso bianco · Riuscito verde · Fallito arancione. Clic destro su un'uscita per scollegarla." : connections.message)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            if let error = draft.validationError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else {
                Text("I cicli rispettano il limite di ogni nodo e un massimo totale di 64 passaggi. Timeout, permessi negati ed errori dei modelli fermano il workflow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Menu("Modelli di partenza") {
                    Button("Vuoto") { load(.empty) }
                    Button("Ricerca") { load(.research) }
                    Button("Loop fino allo score") { load(.scoreLoop) }
                    Button("Sviluppo controllato") { load(.standard) }
                }
                Spacer()
                Button(connections.sourceID == nil ? "Annulla" : "Annulla collegamento") {
                    if connections.sourceID != nil { connections.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button("Salva workflow") { definition = draft; dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(draft.validationError != nil)
            }
        }.padding(20).frame(width: editorSize.width, height: editorSize.height)
        .background(OrbitDesign.screen).foregroundStyle(OrbitDesign.chalk).tint(OrbitDesign.lime).preferredColorScheme(.dark)
        .sheet(isPresented: $showingActions) {
            WorkflowActionPicker(definition: draft, library: library, select: { selected = $0; camera.center(on: draft.node($0).map { CGPoint(x: $0.x + 102.5, y: $0.y + 50) } ?? .zero) }, add: addAction)
        }
    }
    private var editorSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: min(1280, max(960, screen.width - 80)), height: min(820, max(650, screen.height - 100)))
    }
    private func inspector(_ index: Int) -> some View {
        WorkflowNodeInspector(node: $draft.nodes[index], definition: draft, requiresPlanApproval: draft.requiresPlanApproval,
            disconnect: { output in connections.disconnect(sourceID: draft.nodes[index].id, output: output, in: &draft) },
            delete: { deleteAction(index) },
            saveAction: library != nil && draft.nodes[index].kind.canSaveAction ? { _ = library?.wrappedValue.saveAction(draft.nodes[index]) } : nil)
            .id(draft.nodes[index].id)
    }
    private func addAction(_ template: WorkflowNode) {
        let source = draft.isDevelopment ? draft.nodes.first(where: { $0.kind == .implementation })?.id : draft.node(selected)?.id ?? draft.nodes.last?.id
        guard let id = draft.insertNode(template, after: source) else { return }
        selected = id; connections.cancel(); camera.fit(draft.nodes)
    }
    private func deleteAction(_ index: Int) {
        connections.cancel()
        draft.removeNode(draft.nodes[index].id); selected = draft.entry; camera.fit(draft.nodes)
    }
    private func load(_ graph: WorkflowDefinition) {
        connections.cancel(); let name = draft.name; draft = graph; draft.name = name; selected = draft.entry; camera.fit(draft.nodes)
    }

}

struct WorkflowCanvasView: View {
    @Binding var definition: WorkflowDefinition
    @Binding var selected: String
    @Bindable var connections: WorkflowConnectionInteraction
    var camera: WorkflowCanvasCamera? = nil
    @State private var localCamera = WorkflowCanvasCamera()
    private var navigation: WorkflowCanvasCamera { camera ?? localCamera }
    var body: some View {
        WorkflowZoomCanvas(camera: navigation, nodes: definition.nodes) {
            ZStack(alignment: .topLeading) {
                WorkflowCanvasBackdrop { connections.cancel() }
                WorkflowConnections(definition: definition, connections: connections)
                ForEach($definition.nodes) { $node in
                    WorkflowNodeCard(node: $node, selected: node.id == selected, connections: connections,
                        definition: $definition, select: { selected = node.id })
                        .offset(x: WorkflowCanvasCamera.origin.x + node.x - 22, y: WorkflowCanvasCamera.origin.y + node.y)
                }
            }.frame(width: WorkflowCanvasCamera.worldSize.width, height: WorkflowCanvasCamera.worldSize.height, alignment: .topLeading)
        }
        .overlay(alignment: .topLeading) {
            Label(navigation.handTool ? "Mano · trascina per navigare" : "Trascina lo sfondo · pizzica per zoommare", systemImage: navigation.handTool ? "hand.draw" : "move.3d")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
                .background(OrbitDesign.carbon.opacity(0.9), in: RoundedRectangle(cornerRadius: 8)).padding(12).allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) { toolbar.padding(12) }
        .overlay(alignment: .bottomTrailing) { WorkflowMiniMap(nodes: definition.nodes, camera: navigation).padding(12) }
        .frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 360)
        .background(OrbitDesign.carbon).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(OrbitDesign.line))
    }
    private var toolbar: some View {
        HStack(spacing: 4) {
            Button { navigation.handTool.toggle(); connections.cancel() } label: {
                Image(systemName: navigation.handTool ? "hand.draw.fill" : "cursorarrow")
                    .foregroundStyle(navigation.handTool ? OrbitDesign.lime : OrbitDesign.chalk)
            }.accessibilityLabel("Selezione o strumento mano").help("Selezione / mano: con la mano puoi trascinare la vista anche sopra le card")
            Divider().frame(height: 20)
            Button { navigation.setZoom(navigation.zoom / 1.2) } label: { Image(systemName: "minus") }.accessibilityLabel("Riduci zoom").help("Riduci zoom").keyboardShortcut("-", modifiers: .command)
            Menu {
                ForEach([0.25, 0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { scale in
                    Button("\(Int(scale * 100))%") { navigation.setZoom(scale) }
                }
            } label: { Text("\(Int((navigation.zoom * 100).rounded()))%").monospacedDigit().frame(width: 42, height: 28) }
            .menuStyle(.borderlessButton).fixedSize().help("Livello di zoom")
            Button { navigation.setZoom(navigation.zoom * 1.2) } label: { Image(systemName: "plus") }.accessibilityLabel("Aumenta zoom").help("Aumenta zoom").keyboardShortcut("+", modifiers: .command)
            Divider().frame(height: 20)
            Button { navigation.fit(definition.nodes) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Adatta tutto").help("Adatta tutto · ⌘0").keyboardShortcut("0", modifiers: .command)
            Button {
                if let node = definition.node(selected) { navigation.center(on: CGPoint(x: node.x + 102.5, y: node.y + 50)) }
            } label: { Image(systemName: "scope") }.accessibilityLabel("Centra il nodo selezionato").help("Centra il nodo selezionato")
            Button { arrange() } label: { Image(systemName: "rectangle.3.group") }.accessibilityLabel("Riordina i nodi").help("Riordina i nodi nel canvas")
        }.buttonStyle(WorkflowCanvasToolButtonStyle()).font(.system(size: 12)).padding(8)
            .background(OrbitDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(OrbitDesign.line))
    }
    private func arrange() {
        connections.cancel()
        var order: [String] = []; var id: String? = definition.entry
        while let next = id, !order.contains(next), let node = definition.node(next) { order.append(next); id = node.success }
        let others = definition.nodes.map(\.id).filter { !order.contains($0) }
        for (row, ids) in [order, others].enumerated() {
            for (column, id) in ids.enumerated() {
                if let index = definition.nodes.firstIndex(where: { $0.id == id }) {
                    definition.nodes[index].x = Double(column) * 270; definition.nodes[index].y = Double(row) * 220
                }
            }
        }
        navigation.fit(definition.nodes)
    }
}

private struct WorkflowCanvasToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
            .background(configuration.isPressed ? OrbitDesign.line : Color.clear, in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct WorkflowMiniMap: View {
    let nodes: [WorkflowNode]
    @Bindable var camera: WorkflowCanvasCamera
    private var area: CGRect { WorkflowCanvasCamera.graphBounds(nodes).insetBy(dx: -70, dy: -70) }
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / area.width, geometry.size.height / area.height)
            let offset = CGPoint(x: (geometry.size.width - area.width * scale) / 2, y: (geometry.size.height - area.height * scale) / 2)
            Canvas { context, _ in
                context.translateBy(x: offset.x - area.minX * scale, y: offset.y - area.minY * scale)
                context.scaleBy(x: scale, y: scale)
                for node in nodes {
                    context.fill(Path(roundedRect: node.canvasRect, cornerRadius: 10), with: .color(OrbitDesign.chalk.opacity(0.4)))
                }
                let visible = camera.visibleRect.intersection(area)
                if !visible.isNull {
                    context.fill(Path(visible), with: .color(OrbitDesign.lime.opacity(0.08)))
                    context.stroke(Path(visible), with: .color(OrbitDesign.lime), lineWidth: 1 / scale)
                }
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                camera.center(on: CGPoint(x: (value.location.x - offset.x) / scale + area.minX, y: (value.location.y - offset.y) / scale + area.minY))
            })
        }.frame(width: 140, height: 84).background(OrbitDesign.raisedSurface.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(OrbitDesign.line))
            .accessibilityLabel("Mini-mappa del workflow").help("Clicca o trascina per spostare la vista")
    }
}

private struct WorkflowNodeCard: View {
    @Binding var node: WorkflowNode
    let selected: Bool
    @Bindable var connections: WorkflowConnectionInteraction
    @Binding var definition: WorkflowDefinition
    let select: () -> Void
    private var hovered: Bool { connections.isDragging && connections.pointer.flatMap { connections.target(at: $0, in: definition)?.id } == node.id }
    private var validTarget: Bool { connections.error(for: node, in: definition) == nil }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: node.kind.symbol)
                        Text(node.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if node.id == definition.entry { Image(systemName: "play.circle.fill").font(.system(size: 11)).foregroundStyle(OrbitDesign.lime).help("Nodo iniziale") }
                    }
                    Text(node.kind.usesModel ? node.agent.displayName + (node.model.isEmpty ? " · predefinito" : " · " + node.model) : "Max \(node.maxVisits) esecuzioni")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    HStack {
                        Text(node.kind == .evaluation ? "✓ ≥ soglia" : "✓ Riuscito").foregroundStyle(OrbitDesign.lime)
                        Spacer()
                        if node.acceptsFailureConnection { Text(node.kind == .evaluation ? "! Sotto soglia" : "! Fallito").foregroundStyle(.orange) }
                    }.font(.system(size: 10, weight: .medium))
                }.padding(12).frame(width: 205, height: 100, alignment: .leading)
                    .background(OrbitDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(hovered ? (validTarget ? OrbitDesign.lime : .orange) : selected ? OrbitDesign.lime : OrbitDesign.line, lineWidth: hovered || selected ? 2 : 1))
            }.buttonStyle(.plain).accessibilityLabel("Nodo \(node.title)").help("Seleziona o trascina il nodo")
            .overlay {
                WorkflowNodeDragSurface(begin: {
                    connections.cancel()
                    let origin = CGPoint(x: node.x, y: node.y); select(); return origin
                }, move: { point in
                    node.x = min(3800, max(-4000, point.x)); node.y = min(3900, max(-4000, point.y))
                }).accessibilityHidden(true)
            }
            Button {
                if connections.sourceID != nil { connections.connect(to: node.id, in: &definition) } else { select() }
            } label: {
                Circle().fill(hovered && validTarget ? OrbitDesign.lime : OrbitDesign.chalk)
                    .overlay(Circle().stroke(OrbitDesign.carbon, lineWidth: 2)).frame(width: 12, height: 12)
                    .frame(width: 44, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).overlay {
                WorkflowInputPortSurface {
                    if connections.sourceID != nil { connections.connect(to: node.id, in: &definition) } else { select() }
                }.accessibilityHidden(true)
            }.position(x: 0, y: 50)
                .accessibilityLabel("Ingresso di \(node.title)").help("Rilascia qui una connessione, oppure seleziona un'uscita e poi questo ingresso")
            outputPort(.success).position(x: 205, y: 44)
            if node.acceptsFailureConnection { outputPort(.failure).position(x: 205, y: 78) }
        }.frame(width: 205, height: 100, alignment: .topLeading).padding(.horizontal, 22)
    }
    private func outputPort(_ output: WorkflowOutput) -> some View {
        let connected = output.target(in: node) != nil
        let active = connections.sourceID == node.id && connections.output == output
        return Button { connections.begin(source: node, output: output) } label: {
            Circle().fill(connected || active ? output.color : OrbitDesign.carbon)
                .overlay(Circle().stroke(output.color, lineWidth: active ? 3 : 2)).frame(width: 12, height: 12)
                .frame(width: 44, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Uscita \(output.label) di \(node.title)")
        .help("Trascina verso un'altra card. Clic destro per scollegare.")
        .overlay {
            WorkflowConnectionDragSurface(sourceID: node.id, output: output, begin: {
                connections.begin(source: node, output: output)
                return output.point(on: node)
            }, move: { connections.move($0) }, finish: { connections.drop($0, in: &definition) },
                cancel: { connections.cancel() }, disconnect: connected ? { connections.disconnect(sourceID: node.id, output: output, in: &definition) } : nil)
                .accessibilityHidden(true)
        }
    }

}

private struct WorkflowConnections: View {
    let definition: WorkflowDefinition
    @Bindable var connections: WorkflowConnectionInteraction
    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: WorkflowCanvasCamera.origin.x, y: WorkflowCanvasCamera.origin.y)
            for node in definition.nodes {
                for output in WorkflowOutput.allCases {
                    guard let target = definition.node(output.target(in: node)) else { continue }
                    if connections.isDragging && connections.sourceID == node.id && connections.output == output { continue }
                    draw(&context, start: output.point(on: node), end: target.inputPoint, output: output, source: node, target: target)
                }
            }
            if let source = definition.node(connections.sourceID), let point = connections.pointer {
                let target = connections.target(at: point, in: definition)
                let end = connections.isDragging && target != nil ? target!.inputPoint : point
                draw(&context, start: connections.output.point(on: source), end: end, output: connections.output, source: source, target: connections.isDragging ? target : nil, preview: true)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func draw(_ context: inout GraphicsContext, start: CGPoint, end: CGPoint, output: WorkflowOutput, source: WorkflowNode, target: WorkflowNode?, preview: Bool = false) {
        var path = Path(); path.move(to: start)
        let corridor = CGRect(x: min(start.x, end.x), y: min(start.y, end.y) - 8,
            width: abs(end.x - start.x), height: abs(end.y - start.y) + 16)
        let obstructed = definition.nodes.contains { $0.id != source.id && $0.id != target?.id && $0.canvasRect.intersects(corridor) }
        if let target, end.x <= start.x || obstructed {
            // Return branches make a continuous bow around the cards.
            // Both Béziers share a horizontal tangent at the midpoint: no corner.
            let direction = end.x > start.x ? 1.0 : -1.0
            let span = max(45, min(140, abs(end.x - start.x) / 3))
            let handle = max(80, min(160, abs(end.x - start.x) * 0.2))
            let middle = CGPoint(x: (start.x + end.x) / 2,
                y: max(source.y, target.y) + 145 + (output == .failure ? 10 : 0))
            path.addCurve(to: middle, control1: CGPoint(x: start.x + handle, y: start.y),
                control2: CGPoint(x: middle.x - direction * span, y: middle.y))
            path.addCurve(to: end, control1: CGPoint(x: middle.x + direction * span, y: middle.y),
                control2: CGPoint(x: end.x - handle, y: end.y))
        } else {
            let bend = max(35, min(180, hypot(end.x - start.x, end.y - start.y) * 0.4))
            path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
        }
        context.stroke(path, with: .color(output.color.opacity(preview ? 0.95 : 0.8)), style: StrokeStyle(lineWidth: preview ? 3 : 2, lineCap: .round, lineJoin: .round, dash: output == .failure ? [5, 4] : []))
        var arrow = Path(); arrow.move(to: CGPoint(x: end.x - 6, y: end.y - 4)); arrow.addLine(to: end); arrow.addLine(to: CGPoint(x: end.x - 6, y: end.y + 4))
        context.stroke(arrow, with: .color(output.color), lineWidth: 2)
    }
}
