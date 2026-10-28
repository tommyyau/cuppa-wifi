import XCTest

@testable import CuppaPortals

@MainActor
final class PortalMarketingChoiceTests: XCTestCase {
    let h = PortalLegacyAuditTests()

    func testYesNoMarketingDropdownUsesQuestionPolarityRegardlessOfOrder() throws {
        for (question, expected) in [("Send marketing offers", "no"), ("Do not send marketing", "yes")] {
            for answers in ["<option value='yes'>Yes</option><option value='no'>No</option>",
                "<option value='no'>No</option><option value='yes'>Yes</option>"] {
                for required in ["", "required"] {
                    let fields = try h.fillFields("<label>\(question)<select name='contact' \(required)><option value=''>Select</option>\(answers)</select></label>")
                    XCTAssertEqual(fields["contact"], expected, question)
                }
            }
        }
    }

    func testMarketingRadioAnswersInheritLegendWithoutMistakingOptOutForChoiceText() throws {
        for (question, expected) in [("Receive marketing offers", "no"), ("Do not send marketing", "yes")] {
            for order in [["yes", "no"], ["no", "yes"]] {
                let inputs = order.map { value in
                    "<label>\(value.capitalized)<input type='radio' name='contact' value='\(value)' required></label>"
                }.joined()
                XCTAssertEqual(try h.fillFields("<fieldset><legend>\(question)</legend>\(inputs)</fieldset>")["contact"], expected)
            }
        }
        let explicit = "<fieldset><legend>Marketing communications</legend><label>Receive marketing offers<input type='radio' name='contact' value='allow' required></label><label>Do not send marketing<input type='radio' name='contact' value='deny' required></label></fieldset>"
        XCTAssertEqual(try h.fillFields(explicit)["contact"], "deny")
    }

    func testDisabledAndPlaceholderAnswersCannotAuthorizeMarketingChoice() throws {
        for invalid in [
            "<option value='yes' disabled>Yes</option>",
            "<optgroup disabled><option value='yes'>Yes</option></optgroup>",
            "<option value='yes'>Select Yes</option>",
            "<option value=''>Yes</option>",
            "<option value='yes'>Unfamiliar answer</option>",
            "<option value='yes'>Yes</option><option value='also_yes'>Yes</option>",
        ] {
            let select = "<label>Do not send marketing<select name='contact' required>\(invalid)<option value='no' selected>No</option></select></label>"
            XCTAssertThrowsError(try h.fillFields(select)) {
                XCTAssertEqual(($0 as? PortalPolicyError)?.reason, "marketing_consent_required")
            }
            XCTAssertNil(try h.fillFields(select.replacingOccurrences(of: " required", with: ""))["contact"])
        }
        let radio = "<fieldset><legend>Do not send marketing</legend><label>Yes<input name='contact' type='radio' value='yes' disabled></label><label>No<input name='contact' type='radio' value='no' checked required></label></fieldset>"
        XCTAssertThrowsError(try h.fillFields(radio))
        XCTAssertNil(try h.fillFields(radio.replacingOccurrences(of: " required", with: ""))["contact"])
    }

    func testMarketingChoicesUseDisplayedOptionLabelAndPreserveSubmittedValue() throws {
        for answers in [
            "<option value='allow' label='Receive marketing'>No</option><option value='deny' label='No thanks'>Yes</option>",
            "<option value='deny' label='No thanks'>Yes</option><option value='allow' label='Receive marketing'>No</option>",
            "<option value='allow'>Yes</option><option value='deny' label=''>No</option>",
            "<option label='Receive marketing'>No</option><option label='No thanks'>Yes</option>",
        ] {
            let fields = try h.fillFields("<label>Receive marketing<select name='contact' required>\(answers)</select></label>")
            XCTAssertEqual(fields["contact"], answers.contains("value=") ? "deny" : "Yes")
        }
        for refusal in ["<option value='no' label='   '>No</option>",
            "<option value='no' label='Select'>No</option>"] {
            XCTAssertThrowsError(try h.fillFields("<label>Receive marketing<select name='contact' required><option value='allow'>Yes</option>\(refusal)</select></label>"))
        }
    }

    func testExplicitDeclineTextOverridesOpaqueBooleanServerValue() throws {
        XCTAssertEqual(try h.fillFields("<label>Receive marketing offers<select name='contact' required><option value='no'>Receive marketing</option><option value='yes'>No thanks</option></select></label>")["contact"], "yes")
    }
}
