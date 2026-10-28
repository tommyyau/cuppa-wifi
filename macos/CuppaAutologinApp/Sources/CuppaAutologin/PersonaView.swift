import SwiftUI

struct PersonaView: View {
    @ObservedObject var model: StatusModel
    @State private var showsPassword = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 16))
                    Text(
                        "\(model.identity.firstName) \(model.identity.lastName)"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    Text("fictional — never a real identity")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    PersonaField("First name", text: $model.identity.firstName)
                    PersonaField("Last name", text: $model.identity.lastName)
                }

                HStack(spacing: 8) {
                    PersonaField("Email", text: $model.identity.email)
                    Button("Copy") {
                        model.copyPersonaEmail()
                    }
                    .buttonStyle(.coffeeSecondary)
                    .help("Copy the fictional email address")
                }

                HStack(spacing: 8) {
                    PersonaField(
                        "Date of birth",
                        text: $model.identity.dateOfBirth
                    )
                    PersonaField("Postcode", text: $model.identity.postcode)
                }

                HStack(spacing: 8) {
                    PersonaField("Phone", text: $model.identity.phone)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Portal password").font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            if showsPassword {
                                TextField("Portal password", text: $model.identity.password)
                            } else {
                                SecureField("Portal password", text: $model.identity.password)
                            }
                            Button {
                                showsPassword.toggle()
                            } label: {
                                Image(systemName: showsPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
                            .help(showsPassword ? "Hide password" : "Show password")
                        }
                    }
                }

                DisclosureGroup("Additional portal fields") {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            PersonaField("Title", text: $model.identity.title)
                            PersonaField("Gender", text: $model.identity.gender)
                        }

                        PersonaField(
                            "Address line 1",
                            text: $model.identity.addressLine1
                        )
                        PersonaField("Address line 2", text: $model.identity.addressLine2)

                        HStack(spacing: 8) {
                            PersonaField(
                                "Town / city",
                                text: $model.identity.city
                            )
                            PersonaField("County", text: $model.identity.county)
                        }

                        HStack(spacing: 8) {
                            PersonaField("Country", text: $model.identity.country)
                            PersonaField("Company", text: $model.identity.company)
                        }

                        HStack(spacing: 8) {
                            PersonaField(
                                "Occupation",
                                text: $model.identity.occupation
                            )
                            PersonaField(
                                "Reason for visit",
                                text: $model.identity.reasonForVisit
                            )
                        }
                    }
                    .padding(.top, 6)
                    .padding(.leading, 15)
                }

                HStack(spacing: 8) {
                    Button("Save Persona") {
                        model.saveIdentity()
                    }
                    .buttonStyle(.caramelPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.identityHasUnsavedChanges || model.persistentChangesDisabled)

                    Button("Discard Changes") {
                        model.discardIdentityChanges()
                    }
                    .buttonStyle(.coffeeSecondary)
                    .disabled(!model.identityHasUnsavedChanges)

                    Button("Generate Persona") {
                        model.generateIdentity()
                    }
                    .buttonStyle(.coffeeSecondary)
                }
                .padding(.top, 4)

                if !model.message.isEmpty {
                    Text(model.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Text(
                    "Portals use your saved Persona. Recognised optional fields may be filled too; marketing stays off. Codes and genuine credentials need you."
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: 560)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 13))
    }
}

// Keep labels visible when a field is filled or cleared.
private struct PersonaField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(title, text: $text).accessibilityLabel(title)
        }
    }
}
