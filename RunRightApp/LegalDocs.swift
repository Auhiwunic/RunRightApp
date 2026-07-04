//
//  LegalDocs.swift
//  RunRightApp
//
//  In-app access to the bundled legal documents. App Review 3.1.2 requires
//  functional Terms of Use and Privacy Policy links on the subscription
//  screen, and 5.1.1 requires the privacy policy to be reachable in the app.
//  The markdown sources live in legal/ and ship as bundle resources.
//

import SwiftUI

enum LegalDoc: String, Identifiable {
    case privacyPolicy = "PRIVACY_POLICY"
    case terms = "TERMS_AND_CONDITIONS"
    case licenses = "LICENSES"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacyPolicy: return "Privacy Policy"
        case .terms:         return "Terms & Conditions"
        case .licenses:      return "Open Source Licenses"
        }
    }

    var bodyText: String {
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "This document could not be loaded. It is also available on request."
        }
        return text
    }
}

struct LegalDocView: View {
    let doc: LegalDoc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(doc.title)
                            .font(AppTheme.head(20))
                            .foregroundColor(AppTheme.primaryText)
                        Spacer()
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(AppTheme.meta(13))
                                .foregroundColor(AppTheme.primaryText.opacity(0.6))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(AppTheme.primaryText.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 20)

                    Text(doc.bodyText)
                        .font(AppTheme.body(13))
                        .foregroundColor(AppTheme.primaryText.opacity(0.85))
                        .textSelection(.enabled)

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
            }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bgColor)
    }
}
