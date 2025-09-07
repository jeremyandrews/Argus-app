import SwiftUI

// MARK: - ReadingExperienceView

struct ReadingExperienceView: View {
    @Binding var textDisplaySettings: TextDisplaySettings
    let onSettingsChanged: () -> Void
    @State private var showAdvancedSettings = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Quick Presets
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(TextDisplayPreset.presets, id: \.name) { preset in
                        ImprovedPresetCardView(
                            preset: preset,
                            isSelected: isPresetSelected(preset),
                            onTap: {
                                textDisplaySettings = preset.settings
                                onSettingsChanged()
                            }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
            
            // Preview
            VStack(alignment: .leading, spacing: 8) {
                Text("Sample Article Title")
                    .font(textDisplaySettings.font)
                    .foregroundColor(textDisplaySettings.fontColor.color)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(textDisplaySettings.backgroundColor.color)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                
                Text("Sample article text to preview your settings.")
                    .font(textDisplaySettings.descriptionFont)
                    .foregroundColor(textDisplaySettings.fontColor.color.opacity(0.8))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(textDisplaySettings.backgroundColor.color)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
            
            // Advanced Settings - Collapsible with Better Organization
            DisclosureGroup(
                isExpanded: $showAdvancedSettings,
                content: {
                    VStack(alignment: .leading, spacing: 16) {
                        // Font Settings Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Typography")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            
                            // Font Family
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Font Family")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                
                                Menu {
                                    ForEach(FontFamily.allCases, id: \.self) { family in
                                        Button(family.displayName) {
                                            textDisplaySettings.fontFamily = family
                                            onSettingsChanged()
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(textDisplaySettings.fontFamily.displayName)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(10)
                                }
                            }
                            
                            // Font Size and Weight
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Size")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    
                                    Picker("Font Size", selection: $textDisplaySettings.fontSize) {
                                        ForEach(FontSize.allCases, id: \.self) { size in
                                            Text(size.displayName).tag(size)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .onChange(of: textDisplaySettings.fontSize) { _, _ in
                                        onSettingsChanged()
                                    }
                                }
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Weight")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    
                                    Picker("Font Weight", selection: $textDisplaySettings.fontWeight) {
                                        ForEach(FontWeight.allCases, id: \.self) { weight in
                                            Text(weight.displayName).tag(weight)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .onChange(of: textDisplaySettings.fontWeight) { _, _ in
                                        onSettingsChanged()
                                    }
                                }
                            }
                        }
                        
                        Divider()
                        
                        // Color Settings Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Colors")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 20) {
                                // Background Colors
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Background")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                                        ForEach(BackgroundColorOption.allCases, id: \.self) { option in
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(option.color)
                                                .frame(height: 32)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(textDisplaySettings.backgroundColor == option ? Color.blue : Color.secondary.opacity(0.3), lineWidth: textDisplaySettings.backgroundColor == option ? 3 : 1)
                                                )
                                                .onTapGesture {
                                                    textDisplaySettings.backgroundColor = option
                                                    onSettingsChanged()
                                                }
                                        }
                                    }
                                }
                                
                                // Font Colors
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Text Color")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                                        ForEach(FontColorOption.allCases, id: \.self) { option in
                                            Circle()
                                                .fill(option.color)
                                                .frame(height: 32)
                                                .overlay(
                                                    Circle()
                                                        .stroke(textDisplaySettings.fontColor == option ? Color.blue : Color.secondary.opacity(0.3), lineWidth: textDisplaySettings.fontColor == option ? 3 : 1)
                                                )
                                                .onTapGesture {
                                                    textDisplaySettings.fontColor = option
                                                    onSettingsChanged()
                                                }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                },
                label: {
                    HStack {
                        Text("Advanced Settings")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: showAdvancedSettings ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            )
            .accentColor(.primary)
        }
    }
    
    private func isPresetSelected(_ preset: TextDisplayPreset) -> Bool {
        return textDisplaySettings.fontFamily == preset.settings.fontFamily &&
               textDisplaySettings.fontSize == preset.settings.fontSize &&
               textDisplaySettings.fontWeight == preset.settings.fontWeight &&
               textDisplaySettings.backgroundColor == preset.settings.backgroundColor &&
               textDisplaySettings.fontColor == preset.settings.fontColor
    }
}

// MARK: - ImprovedPresetCardView

struct ImprovedPresetCardView: View {
    let preset: TextDisplayPreset
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Live preview of the preset
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.name)
                    .font(preset.settings.font.weight(.semibold))
                    .foregroundColor(preset.settings.fontColor.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                
                Text(preset.description)
                    .font(preset.settings.descriptionFont)
                    .foregroundColor(preset.settings.fontColor.color.opacity(0.75))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 150, height: 65)
            .background(preset.settings.backgroundColor.color)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.2), lineWidth: isSelected ? 3 : 1)
            )
            .shadow(color: Color.black.opacity(0.1), radius: isSelected ? 4 : 2, x: 0, y: 1)
            
            // Preset name below the preview
            Text(preset.name)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(isSelected ? .blue : .secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .center)
        }
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .onTapGesture {
            onTap()
        }
    }
}

// MARK: - Preview

struct ReadingExperienceView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            Section {
                ReadingExperienceView(
                    textDisplaySettings: .constant(UserDefaults.standard.textDisplaySettings),
                    onSettingsChanged: {}
                )
            } header: {
                Text("Reading Experience")
            } footer: {
                Text("Customize how articles appear when reading. Choose a preset or create your own style.")
            }
        }
    }
}
