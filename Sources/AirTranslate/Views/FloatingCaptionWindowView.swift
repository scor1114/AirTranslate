import SwiftUI

struct FloatingCaptionWindowView: View {
    @Bindable var session: TranslationSessionStore

    private static let lineSpacing: CGFloat = 5
    private static let blockSpacing: CGFloat = 8
    private static let replacementCrossfadeDuration = 0.16

    var body: some View {
        ZStack {
            AirTranslateDesign.Palette.transparent

            VStack(spacing: Self.blockSpacing) {
                content
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                if session.floatingCaptionMeasuredTextWidth != width {
                    session.floatingCaptionMeasuredTextWidth = width
                }
            }
            .padding(.horizontal, AirTranslateDesign.Spacing.lg)
            .padding(.vertical, AirTranslateDesign.Spacing.md)
            .background {
                if hasVisibleCaptionText {
                    RoundedRectangle(cornerRadius: AirTranslateDesign.Radius.surface, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AirTranslateDesign.Palette.floatingScrimTop,
                                    AirTranslateDesign.Palette.floatingScrimBottom
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: AirTranslateDesign.Radius.surface, style: .continuous)
                                .strokeBorder(AirTranslateDesign.Palette.floatingOutline)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 420, idealWidth: 720, maxWidth: 960, minHeight: 90, idealHeight: preferredHeight, maxHeight: preferredHeight)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .overlay {
            FloatingCaptionDragSurface()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            FloatingWindowConfigurator(
                preferredContentHeight: preferredHeight,
                keepsAboveOtherWindows: session.keepsFloatingCaptionAboveOtherWindows
            )
        )
    }

    /// Every caption block reserves the full height for its configured line
    /// count and anchors its text to the seam between blocks. Line-count changes
    /// and roll-ups therefore never move the neighbouring block.
    @ViewBuilder
    private var content: some View {
        switch session.floatingCaptionDisplayMode {
        case .original:
            primaryBlock(sourceText.isEmpty ? AppText.noFloatingCaptionsYet : sourceText, anchor: .bottom)
            if !noticeText.isEmpty {
                secondaryBlock(noticeText, anchor: .top)
            }
        case .originalAndTranslation:
            if sourceText.isEmpty, translationText.isEmpty, noticeText.isEmpty {
                primaryBlock(AppText.noFloatingCaptionsYet, anchor: .bottom)
                    .frame(height: primaryBlockHeight + secondaryBlockHeight + Self.blockSpacing)
            } else {
                secondaryBlock(sourceText, anchor: .bottom)
                if !translationText.isEmpty {
                    primaryBlock(translationText, anchor: .top)
                } else if !noticeText.isEmpty {
                    primaryBlock(noticeText, anchor: .top, font: session.floatingCaptionTextSize.secondaryFont)
                } else {
                    primaryBlock("", anchor: .top)
                }
            }
        case .translation:
            if !translationText.isEmpty {
                primaryBlock(translationText, anchor: .bottom)
            } else if !noticeText.isEmpty {
                primaryBlock(noticeText, anchor: .bottom, font: session.floatingCaptionTextSize.secondaryFont)
            } else if sourceText.isEmpty {
                primaryBlock(AppText.noFloatingCaptionsYet, anchor: .bottom)
            } else {
                primaryBlock(AppText.translating, anchor: .bottom, font: session.floatingCaptionTextSize.secondaryFont)
            }
        }
    }

    private var sourceText: String {
        session.floatingSourceText
    }

    private var translationText: String {
        session.floatingTranslationText
    }

    private var noticeText: String {
        session.floatingNoticeText ?? ""
    }

    private var hasVisibleCaptionText: Bool {
        switch session.floatingCaptionDisplayMode {
        case .original, .originalAndTranslation:
            true
        case .translation:
            true
        }
    }

    private var lineLimit: Int {
        session.floatingCaptionLineCount.rawValue
    }

    private var alignment: FloatingCaptionTextAlignment {
        session.floatingCaptionTextAlignment
    }

    static func blockHeight(lineHeight: CGFloat, lineCount: Int) -> CGFloat {
        lineHeight * CGFloat(lineCount) + CGFloat(max(0, lineCount - 1)) * lineSpacing
    }

    private var primaryBlockHeight: CGFloat {
        Self.blockHeight(lineHeight: session.floatingCaptionTextSize.primaryLineHeight, lineCount: lineLimit)
    }

    private var secondaryBlockHeight: CGFloat {
        Self.blockHeight(lineHeight: session.floatingCaptionTextSize.secondaryLineHeight, lineCount: lineLimit)
    }

    private var preferredHeight: CGFloat {
        let textHeight: CGFloat

        switch session.floatingCaptionDisplayMode {
        case .original, .translation:
            textHeight = noticeText.isEmpty
                ? primaryBlockHeight
                : primaryBlockHeight + secondaryBlockHeight + Self.blockSpacing
        case .originalAndTranslation:
            textHeight = primaryBlockHeight + secondaryBlockHeight + Self.blockSpacing
        }

        return min(max(90, textHeight + 28), 720)
    }

    private func primaryBlock(_ text: String, anchor: VerticalAlignment, font: Font? = nil) -> some View {
        captionBlock(
            text,
            font: font ?? session.floatingCaptionTextSize.primaryFont,
            color: font == nil
                ? AirTranslateDesign.Palette.floatingTextPrimary
                : AirTranslateDesign.Palette.floatingTextSecondary,
            height: primaryBlockHeight,
            anchor: anchor
        )
    }

    private func secondaryBlock(_ text: String, anchor: VerticalAlignment) -> some View {
        captionBlock(
            text,
            font: session.floatingCaptionTextSize.secondaryFont,
            color: AirTranslateDesign.Palette.floatingTextSecondary,
            height: secondaryBlockHeight,
            anchor: anchor
        )
    }

    private func captionBlock(
        _ text: String,
        font: Font,
        color: Color,
        height: CGFloat,
        anchor: VerticalAlignment
    ) -> some View {
        StreamingTranscriptText(
            text: text,
            font: font,
            foregroundColor: color,
            isTextSelectionEnabled: false,
            lineLimit: lineLimit,
            textAlignment: alignment.textAlignment,
            frameAlignment: alignment.frameAlignment(vertical: anchor),
            truncationMode: .tail,
            streamsAppendedTextInChunks: false,
            replacementCrossfadeDuration: Self.replacementCrossfadeDuration
        )
        .multilineTextAlignment(alignment.textAlignment)
        .lineSpacing(Self.lineSpacing)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: alignment.frameAlignment(vertical: anchor))
        .clipped()
        .shadow(color: AirTranslateDesign.Palette.floatingShadow, radius: 8, x: 0, y: 2)
    }
}
