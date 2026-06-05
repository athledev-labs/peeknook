// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Canonical option lists for preflight controls (home command bar + Settings rows).
public enum PeekPreflightOptions {
    public static let captureScopes: [CaptureScope] = CaptureScope.allCases
    public static let answerDepths: [AnswerDepth] = AnswerDepth.allCases
    public static let visionModels: [InferenceModelOption] = TextModelCatalog.offered
}
