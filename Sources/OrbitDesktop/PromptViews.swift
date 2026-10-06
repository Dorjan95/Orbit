import OrbitCore
import SwiftUI

struct AgentPromptView: View {
  @Bindable var controller: OrbitController
  let job: UUID
  let prompt: AgentPrompt
  @State private var answers: [String: String] = [:]
  @State private var form: [String: JSONValue] = [:]
  @State private var openedLink = false
  @State private var validation: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(prompt.title, systemImage: "hand.raised").font(.system(size: 14, weight: .bold))
      if !prompt.details.isEmpty {
        if prompt.details.count > 1200 {
          ScrollView {
            Text(prompt.details).font(.system(size: 12)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 240)
        } else {
          Text(prompt.details).font(.system(size: 12)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      ForEach(prompt.questions) { question in
        VStack(alignment: .leading, spacing: 8) {
          Text(question.title).font(.system(size: 13, weight: .semibold))
          ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
            Button {
              answers[question.id] = option
            } label: {
              HStack(alignment: .top) {
                Image(
                  systemName: answers[question.id] == option ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading, spacing: 3) {
                  Text(option)
                  if index < question.descriptions.count {
                    Text(question.descriptions[index]).font(.system(size: 11)).foregroundStyle(
                      Palette.muted)
                  }
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
          }
          if question.secret {
            SecureField("Risposta riservata", text: answer(question.id)).textFieldStyle(
              .roundedBorder)
          } else {
            TextField("La tua risposta…", text: answer(question.id)).textFieldStyle(.roundedBorder)
          }
        }
      }
      if prompt.kind == .form {
        if prompt.canAccept {
          ForEach(prompt.params["requestedSchema"]["properties"].object.keys.sorted(), id: \.self) {
            key in
            MCPFormField(
              name: key, schema: prompt.params["requestedSchema"]["properties"][key],
              required: prompt.params["requestedSchema"]["required"].array.contains(.string(key)),
              values: $form)
          }
        } else {
          Text(
            "Questo modulo contiene campi non supportati. Rifiuta la richiesta e completa il passaggio dal client Codex."
          )
          .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
      }
      if prompt.kind == .url {
        if let url = prompt.url {
          Text(url.absoluteString).font(.system(size: 11)).textSelection(.enabled)
          Button("Apri la pagina di autorizzazione") {
            openedLink = NSWorkspace.shared.open(url)
          }
          Text("Completa il passaggio nel browser, poi conferma qui.")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        } else {
          Text("Il collegamento ricevuto non è valido.")
        }
      }
      if let validation { Text(validation).font(.system(size: 12)).foregroundStyle(.orange) }
      HStack {
        Button(prompt.kind == .questions ? "Salta le domande" : "Rifiuta") {
          controller.respond(job, request: prompt.id, accept: false)
        }
        Spacer()
        Button(acceptTitle) {
          do {
            _ = try prompt.response(accept: true, answers: answers, form: .object(form))
            validation = nil
            controller.respond(
              job, request: prompt.id, accept: true, answers: answers, form: .object(form))
          } catch { validation = error.localizedDescription }
        }.tint(Palette.accent).disabled(!prompt.canAccept || (prompt.kind == .url && !openedLink))
      }.buttonStyle(.bordered).disabled(controller.replying.contains(job))
      if [.command, .files, .permissions].contains(prompt.kind) {
        Text(
          "Valido per questa richiesta. Puoi dire «approva» o «rifiuta» nella sessione selezionata."
        )
        .font(.system(size: 10)).foregroundStyle(Palette.muted)
      }
    }.padding(14).background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.accent.opacity(0.3)))
  }
  var acceptTitle: String {
    switch prompt.kind {
    case .questions, .form: "Invia risposta"
    case .url: "Ho completato il passaggio"
    case .permissions: "Consenti per questo lavoro"
    default: "Approva una volta"
    }
  }
  func answer(_ key: String) -> Binding<String> {
    Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 })
  }
}

private struct MCPFormField: View {
  let name: String
  let schema: JSONValue
  let required: Bool
  @Binding var values: [String: JSONValue]
  @State private var input = ""
  var options: [JSONValue] {
    let rule = schema["type"].string == "array" ? schema["items"] : schema
    if !rule["enum"].array.isEmpty { return rule["enum"].array }
    return (rule["oneOf"].array + rule["anyOf"].array).map { $0["const"] }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text((schema["title"].string ?? name) + (required ? " *" : ""))
        .font(.system(size: 12, weight: .semibold))
      if let description = schema["description"].string {
        Text(description).font(.system(size: 11)).foregroundStyle(Palette.muted)
      }
      if schema["type"].string == "boolean" {
        Picker(
          name,
          selection: Binding(
            get: { values[name]?.bool.map { $0 ? "yes" : "no" } ?? "" },
            set: { values[name] = $0.isEmpty ? nil : .bool($0 == "yes") })
        ) {
          Text("Scegli…").tag("")
          Text("Sì").tag("yes")
          Text("No").tag("no")
        }.labelsHidden()
      } else if schema["type"].string == "array", !options.isEmpty {
        ForEach(options, id: \.self) { option in
          Toggle(
            option.string ?? "",
            isOn: Binding(
              get: { values[name]?.array.contains(option) ?? false },
              set: { checked in
                var chosen = values[name]?.array ?? []
                chosen.removeAll { $0 == option }
                if checked { chosen.append(option) }
                values[name] = .array(chosen)
              }))
        }
      } else if !options.isEmpty {
        Picker(
          name,
          selection: Binding(
            get: { values[name]?.string ?? "" }, set: { values[name] = .string($0) })
        ) {
          Text("Scegli…").tag("")
          ForEach(options, id: \.self) { Text($0.string ?? "").tag($0.string ?? "") }
        }.labelsHidden()
      } else {
        TextField(
          schema["type"].string == "array" ? "Una voce per riga" : "Inserisci il valore",
          text: Binding(
            get: { input },
            set: { text in
              input = text
              if text.isEmpty && !required {
                values[name] = nil
              } else if ["number", "integer"].contains(schema["type"].string ?? "") {
                values[name] = Double(text).map(JSONValue.number) ?? .string(text)
              } else if schema["type"].string == "array" {
                values[name] = .array(text.split(separator: "\n").map { .string(String($0)) })
              } else {
                values[name] = .string(text)
              }
            }), axis: schema["type"].string == "array" ? .vertical : .horizontal
        ).textFieldStyle(.roundedBorder)
      }
    }.onAppear {
      if values[name] == nil, schema["default"] != .null { values[name] = schema["default"] }
      if let text = values[name]?.string {
        input = text
      } else if let number = values[name]?.number {
        input = String(number)
      } else {
        input = values[name]?.array.compactMap(\.string).joined(separator: "\n") ?? ""
      }
    }
  }
}

struct IntegrationsList: View {
  let items: [ToolIntegration]
  var body: some View {
    ForEach(items) { item in
      DisclosureGroup {
        if let error = item.error { Text(error).foregroundStyle(.orange) }
        if item.tools.isEmpty {
          Text("Nessuno strumento disponibile").foregroundStyle(Palette.muted)
        } else {
          Text(item.tools.joined(separator: " · ")).textSelection(.enabled)
        }
      } label: {
        HStack {
          Label(item.name, systemImage: "puzzlepiece.extension")
          Spacer()
          Text("\(item.tools.count) strumenti").foregroundStyle(Palette.muted)
          if item.auth == "notLoggedIn" { Text("Login richiesto").foregroundStyle(.orange) }
          if !item.status.isEmpty { Text(item.status).foregroundStyle(Palette.muted) }
        }
      }.font(.system(size: 11))
    }
  }
}
