import SwiftUI
import TBDDesign
import UniformTypeIdentifiers

struct EditableCategoryCard: View {
  enum Field: Hashable {
    case name
    case description
  }

  let category: TimelineCategory
  let isEditing: Bool
  @Binding var draftName: String
  @Binding var draftDetails: String
  var onStartEdit: () -> Void
  var onSave: () -> Void
  var onDelete: () -> Void

  @FocusState private var focusedField: Field?

  var body: some View {
    Group {
      if isEditing {
        editingView
          .onAppear {
            focusedField = .name
          }
          .onDisappear {
            focusedField = nil
          }
      } else {
        displayView
      }
    }
  }

  private var editingView: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 12) {
        TextField("", text: $draftName)
          .tbdField(focused: focusedField == .name)
          .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightLabel))
          .submitLabel(.next)
          .focused($focusedField, equals: .name)
          .onSubmit {
            focusedField = .description
          }

        Spacer(minLength: 12)

        Button {
          focusedField = nil
          onSave()
        } label: {
          Image(systemName: "checkmark")
            .font(TBDFonts.symbol(14, TBDKit.weightLabel))
            .accessibilityLabel("Save category edits")
        }
        .buttonStyle(TBDButtonStyle(.icon))

      }

      ZStack(alignment: .topLeading) {
        if draftDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("Professional, school, or career-focused tasks (coding, design, meetings).")
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
            .foregroundStyle(TBDColor.fieldPlaceholder)
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }

        TextEditor(text: $draftDetails)
          .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
          .foregroundStyle(TBDColor.fieldOn)
          .padding(.horizontal, 10)
          .padding(.top, 10)
          .padding(.bottom, 12)
          .frame(minHeight: 55)
          .background(TBDColor.fieldFill, in: TBDBrickShape())
          .focused($focusedField, equals: .description)
          .scrollContentBackground(.hidden)
      }
      .overlay(TBDBrickShape().strokeBorder(TBDColor.fieldEdge, lineWidth: TBDKit.hair))
      .tbdFocusRing(focusedField == .description, offset: TBDKit.focusOffsetTight)
    }
    .frame(alignment: .leading)
    .tbdCard(padding: 16)
  }

  private var displayView: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(category.name)
          .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightLabel))
          .foregroundStyle(TBDColor.ink)
          .frame(maxWidth: .infinity, alignment: .center)

        Text(
          category.details.isEmpty
            ? String(localized: "Add a description to help Tealbrick understand your workflow.")
            : category.details
        )
        .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
        .foregroundStyle(TBDColor.muted)
        .frame(maxWidth: .infinity, alignment: .center)
        .lineLimit(2)
      }

      Spacer()

      if !category.isSystem {
        Button {
          onStartEdit()
        } label: {
          Image(systemName: "pencil")
            .font(TBDFonts.symbol(14, TBDKit.weightNav))
            .accessibilityLabel("Edit category")
        }
        .buttonStyle(TBDButtonStyle(.icon))
        .pointingHandCursor()

        Button {
          onDelete()
        } label: {
          Image(systemName: "trash")
            .font(TBDFonts.symbol(14, TBDKit.weightNav))
            .accessibilityLabel("Delete category")
        }
        .buttonStyle(TBDButtonStyle(.icon))
        .pointingHandCursor()
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .center)
    .tbdCard(padding: 0)
    .contentShape(Rectangle())
    .onTapGesture {
      if !category.isSystem {
        onStartEdit()
      }
    }
    .pointingHandCursor(enabled: !category.isSystem)
  }
}

struct ColorAssignmentCard: View {
  let category: TimelineCategory
  var showDetails: Bool = true
  var onColorDrop: (String) -> Void

  @State private var isTargeted = false

  private func colorSwatch(_ hex: String) -> some View {
    let color: Color = hex.isEmpty ? TBDColor.handSwatch : Color(hex: hex)  // design-guard: allow (user category colour)
    return Rectangle()
      .foregroundStyle(Color.clear)
      .frame(width: 18, height: 18)
      .background(color)
      .clipShape(TBDBrickShape())
      .overlay(
        TBDBrickShape()
          .strokeBorder(TBDColor.lineStrong, lineWidth: TBDKit.hair)
      )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 14) {
        colorSwatch(category.colorHex)

        VStack(alignment: .leading, spacing: 4) {
          Text(category.name)
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightLabel))
            .foregroundStyle(TBDColor.ink)

          if showDetails
            && !category.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            Text(category.details)
              .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
              .foregroundStyle(TBDColor.muted)
              .lineLimit(2)
          }
        }

        Spacer()
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .center)
    .background(TBDColor.tile, in: TBDBrickShape())
    .overlay(
      TBDBrickShape()
        .strokeBorder(isTargeted ? TBDColor.tealInk : TBDColor.line, lineWidth: isTargeted ? 2 : TBDKit.hair)
    )
    .contentShape(Rectangle())
    .onDrop(of: [UTType.plainText], isTargeted: $isTargeted) { providers in
      guard let provider = providers.first else { return false }
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
        let value: String? = {
          if let data = item as? Data { return String(data: data, encoding: .utf8) }
          if let string = item as? String { return string }
          if let ns = item as? NSString { return ns as String }
          return nil
        }()
        if let hex = value {
          DispatchQueue.main.async {
            onColorDrop(hex)
          }
        }
      }
      return true
    }
  }
}
