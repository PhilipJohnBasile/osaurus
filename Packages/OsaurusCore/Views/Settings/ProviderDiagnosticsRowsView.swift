//
//  ProviderDiagnosticsRowsView.swift
//  osaurus
//
//  Shared compact diagnostics renderer for provider settings rows.
//
//  Developer Mode aware: with the mode off, only actionable rows
//  (warning / blocked) render — under a plain "Needs attention" header,
//  without the copy-report affordance — so normal users still see why a
//  provider is failing and what to do, while ok/info internals and the
//  raw copied report stay a developer surface. With the mode on, the
//  full report renders as before.
//

import AppKit
import SwiftUI

struct ProviderDiagnosticsRowsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var developerMode = DeveloperModeSettings.shared

    let report: ProviderDiagnosticReport
    var maxRows: Int?

    private var relevantRows: [ProviderDiagnosticRow] {
        guard !developerMode.isEnabled else { return report.rows }
        return report.rows.filter { $0.severity == .warning || $0.severity == .blocked }
    }

    private var visibleRows: [ProviderDiagnosticRow] {
        guard let maxRows else { return relevantRows }
        return Array(relevantRows.prefix(maxRows))
    }

    private var hiddenCount: Int {
        max(0, relevantRows.count - visibleRows.count)
    }

    var body: some View {
        if developerMode.isEnabled || !relevantRows.isEmpty {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: developerMode.isEnabled ? "stethoscope" : "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                Text(developerMode.isEnabled ? "Diagnostics" : "Needs attention", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                if developerMode.isEnabled {
                    Button(action: copyReport) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Copy")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(visibleRows) { row in
                    diagnosticRow(row)
                }
                if hiddenCount > 0 {
                    if developerMode.isEnabled {
                        Text("+\(hiddenCount) more in copied report", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    } else {
                        Text("+\(hiddenCount) more", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func diagnosticRow(_ row: ProviderDiagnosticRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: row.severity))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color(for: row.severity))
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Text(row.value)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                }

                if let action = row.action, !action.isEmpty {
                    Text(action)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(color(for: row.severity))
                        .lineLimit(2)
                }
            }
        }
    }

    private func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.pasteboardText, forType: .string)
    }

    private func color(for severity: ProviderDiagnosticSeverity) -> Color {
        switch severity {
        case .ok:
            return theme.successColor
        case .info:
            return theme.infoColor
        case .warning:
            return theme.warningColor
        case .blocked:
            return theme.errorColor
        }
    }

    private func icon(for severity: ProviderDiagnosticSeverity) -> String {
        switch severity {
        case .ok:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .blocked:
            return "xmark.octagon.fill"
        }
    }
}
