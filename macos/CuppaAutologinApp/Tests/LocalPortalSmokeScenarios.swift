import Foundation

/// These are production WebKit fixtures: handlers grant only after receiving
/// the exact configured values. No expected answer is passed to the model.
extension NativeWebViewSmoke {
    static let ordinaryControlScenarios: [Scenario] = [
        Scenario(name: "ordinary submit works with local reasoning enabled", html: """
          <form><input id="email" type="email" required><button type="submit" onclick="event.preventDefault();if(email.value==='sarah.chen.wifi@gmail.com')document.body.textContent='Connected';else failSmokeTest()">→</button></form><script>\(failureScript)</script>
          """, expected: .submitted, deterministicBypass: true),
        Scenario(name: "country alias Britain with GB value", html: """
          <form><select id="country" name="country" required><option value="">Choose</option><option value="GB">Britain</option><option value="FR">France</option></select>
          <button type="button" onclick="if(country.value==='GB')document.body.textContent='Connected';else failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .submitted),
        Scenario(name: "zero based month values select March", html: """
          <form><select id="month" name="dobMonth" required><option value="">Choose</option><option value="0">January</option><option value="1">February</option><option value="2">March</option><option value="3">April</option></select>
          <button type="button" onclick="if(month.value==='2')document.body.textContent='Connected';else failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .submitted),
        Scenario(name: "conditional phone appears during initial fill", html: """
          <form><input id="email" type="email" required oninput="reveal()"><span id="extra"></span><button id="go" type="button" disabled onclick="finish()">Continue</button></form>
          <script>\(failureScript)
          function reveal(){if(!document.getElementById('phone'))extra.innerHTML='<input id="phone" type="tel" required oninput="go.disabled=false">'}
          function finish(){if(email.value==='sarah.chen.wifi@gmail.com'&&phone.value==='07700900123')document.body.textContent='Connected';else failSmokeTest()}
          </script>
          """, expected: .submitted),
        Scenario(name: "terms radio corrects initially selected No", html: """
          <form><fieldset><legend>Agree to Wi-Fi terms and conditions</legend><label><input type="radio" name="accept" value="no" checked required>No</label><label><input id="yes" type="radio" name="accept" value="yes" required>Yes</label></fieldset>
          <button type="button" onclick="if(yes.checked)document.body.textContent='Connected';else failSmokeTest()">Continue</button></form><script>\(failureScript)</script>
          """, expected: .submitted),
        Scenario(name: "accessible custom country dropdown", html: countryWidget(label: "Country"), expected: .submitted),
        Scenario(name: "custom dropdown is reselected after a stage resets it", html: countryWidget(label: "Country", repeatStage: true), expected: .submitted),
        Scenario(name: "shadow labels and descriptions resolve in their own root", html: """
          <div id="portal"></div><script>\(failureScript)
          var root=portal.attachShadow({mode:'open'});root.innerHTML='<form><label for="opaque">Email address</label><input id="opaque" required aria-describedby="hint"><span id="hint">Used for registration</span><button type="button">Connect</button></form>';
          root.querySelector('button').onclick=function(){if(root.querySelector('input').value==='sarah.chen.wifi@gmail.com')document.body.textContent='Connected';else failSmokeTest()};
          </script>
          """, expected: .submitted),
        Scenario(name: "accessible required terms radio group", html: """
          <form><div role="radiogroup" aria-label="Agree to Wi-Fi terms and conditions" aria-required="true"><div role="radio" aria-label="No" data-value="no" aria-checked="false" onclick="this.setAttribute('aria-checked','true')">No</div><div id="yes" role="radio" aria-label="Yes" data-value="yes" aria-checked="false" onclick="this.setAttribute('aria-checked','true')">Yes</div></div>
          <button type="button" onclick="if(yes.getAttribute('aria-checked')==='true')document.body.textContent='Connected';else failSmokeTest()">Continue</button></form><script>\(failureScript)</script>
          """, expected: .submitted),
        Scenario(name: "unknown required radio remains unresolved", html: """
          <form><label><input type="radio" name="opaque" value="x" required>Alpha</label><label><input type="radio" name="opaque" value="y" required>Beta</label><button type="button" onclick="failSmokeTest()">Continue</button></form><script>\(failureScript)</script>
          """, expected: .failed),
        Scenario(name: "opt out radio chooses Yes to decline communications", html: """
          <form><fieldset><legend>Do not send marketing communications</legend><label><input type="radio" name="optout" value="no" required>No</label><label><input id="yes" type="radio" name="optout" value="yes" required>Yes</label></fieldset>
          <button type="button" onclick="if(yes.checked)document.body.textContent='Connected';else failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .submitted),
        Scenario(name: "reservation credentials stop before local interpretation", html: """
          <form><h1>Free hotel guest Wi-Fi</h1><label>Référence de réservation<input name="opaque" required></label><button type="button" onclick="failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .unsupported("voucher_or_venue_credential_required"), stopBeforeAction: true),
        Scenario(name: "issued personal reference is never treated as a name", html: """
          <form><h1>Free hotel guest Wi-Fi</h1><label>Personal reference issued at reception<input name="opaque" required></label><button type="button" onclick="failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .unsupported("voucher_or_venue_credential_required"), stopBeforeAction: true),
    ]

    static let localModelScenarios: [Scenario] = [
        Scenario(name: "conversational description with translated recipient name", html: """
          <form><label for="opaque">Guest details</label><input id="opaque" required aria-describedby="explanation"><p id="explanation">Please tell us how to address our greeting: Nombre completo.</p>
          <button type="button" onclick="if(opaque.value==='Sarah Chen')document.body.textContent='Connected';else failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .submitted, localModel: true, minimumReasoningRequests: 2),
        Scenario(name: "mixed language identity description is reviewed before filling", html: """
          <form><h1>Free guest Wi-Fi registration</h1><label for="opaque">Guest identity</label><input id="opaque" required aria-describedby="hint"><p id="hint">Pour vous identifier : nome e cognome.</p>
          <button type="button" onclick="if(opaque.value==='Sarah Chen')document.body.textContent='Connected';else failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .submitted, localModel: true, minimumReasoningRequests: 2),
        Scenario(name: "translated compound name with unrelated page address wording", html: """
          <form><h1>Address your registration details</h1><label for="identity">Como devemos chamar você?</label><input id="identity" required aria-describedby="description"><p id="description">Nombre y apellidos, en una sola casilla.</p><input type="email" id="email" required>
          <button type="button" onclick="if(identity.value==='Sarah Chen'&&email.value==='sarah.chen.wifi@gmail.com')document.body.textContent='Connected';else failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .submitted, localModel: true, minimumReasoningRequests: 2),
        Scenario(name: "French ordinary identity labels", html: """
          <form><h1>Inscription au Wi-Fi gratuit</h1><label>Prénom<input id="x1" required></label><label>Nom de famille<input id="x2" required></label><input id="email" type="email" required>
          <button type="button" onclick="if(x1.value==='Sarah'&&x2.value==='Chen'&&email.value==='sarah.chen.wifi@gmail.com')document.body.textContent='Connected';else failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .submitted, localModel: true),
        Scenario(name: "French zero based month choices", html: """
          <form><h1>Free guest Wi-Fi registration</h1><label>Birth month<select id="month" autocomplete="bday-month" required><option value="">Choose</option><option value="0">Janvier</option><option value="1">Février</option><option value="2">Mars</option><option value="3">Avril</option></select></label>
          <button type="button" onclick="if(month.value==='2')document.body.textContent='Connected';else failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .submitted, localModel: true),
        Scenario(name: "ambiguous custom country control", html: countryWidget(label: "Pays de résidence"), expected: .submitted, localModel: true),
        Scenario(name: "unfamiliar action across two stages", html: """
          <form><h1>Free guest Wi-Fi registration</h1><input id="email" type="email" required><button type="button" onclick="next()">Proceed</button></form>
          <script>\(failureScript)
          function next(){if(email.value!=='sarah.chen.wifi@gmail.com')return failSmokeTest();document.body.innerHTML=`<form><h1>Your free Wi-Fi is ready</h1><button type="button" onclick="document.body.textContent='Connected'">Begin browsing</button></form>`}
          </script>
          """, expected: .submitted, localModel: true),
        Scenario(name: "radio choice prefers withholding gender", html: """
          <form><h1>Free guest Wi-Fi registration</h1><fieldset><legend>Gender</legend><label><input type="radio" name="gender" value="m" required>Male</label><label><input id="private" type="radio" name="gender" value="private" required>I'd rather keep that private</label></fieldset>
          <button type="button" onclick="if(document.getElementById('private').checked)document.body.textContent='Connected';else failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .submitted, localModel: true),
        Scenario(name: "local inference identifies delivered email digits", html: """
          <form><h1>Wi-Fi : confirmez votre adresse électronique</h1><label>Saisissez les six chiffres reçus par courriel<input name="opaque" type="number" required></label><button type="button" onclick="failSmokeTest()">Continue</button></form><script>\(failureScript)</script>
          """, expected: .unsupported("verification_code_required"), localModel: true),
        Scenario(name: "unexplained required identifier is never fabricated", html: """
          <form><h1>Free guest Wi-Fi registration</h1><label>Additional mandatory identifier<input name="opaque" required></label><button type="button" onclick="failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .unsupported("unknown_required_field"), deterministicBypass: true),
        Scenario(name: "local action declines optional marketing stage", html: """
          <form><h1>Would you like occasional news and promotional messages?</h1><button type="button" onclick="failSmokeTest()">Oui, abonnez-moi</button><button type="button" onclick="document.body.textContent='Connected'">Non merci, accéder au Wi-Fi gratuit</button></form><script>\(failureScript)</script>
          """, expected: .submitted, localModel: true),
        Scenario(name: "unfamiliar form-associated external continuation", html: """
          <form id="registration"><h1>Free guest Wi-Fi registration</h1><input id="email" type="email" required></form>
          <button type="button" form="registration" onclick="if(email.value==='sarah.chen.wifi@gmail.com')document.body.textContent='Connected';else failSmokeTest()">Proceed</button><script>\(failureScript)</script>
          """, expected: .submitted, localModel: true),
        Scenario(name: "French optional prechecked newsletter is declined", html: """
          <form><h1>Free guest Wi-Fi registration</h1><input id="email" type="email" required><label><input id="offers" type="checkbox" checked>Recevoir notre lettre d'information</label>
          <button type="button" onclick="if(email.value==='sarah.chen.wifi@gmail.com'&&!offers.checked)document.body.textContent='Connected';else failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .submitted, localModel: true),
    ]

    private static func countryWidget(label: String, repeatStage: Bool = false) -> String {
        """
        <form><h1>Free guest Wi-Fi registration</h1><button id="choiceBox" type="button" role="combobox" aria-label="\(label)" aria-controls="countries" aria-expanded="false" aria-required="true" onclick="countries.hidden=false;this.setAttribute('aria-expanded','true')">Choose</button>
        <div id="countries" role="listbox" hidden><div role="option" data-value="FR" onclick="failSmokeTest()">France</div><div role="option" data-value="GB" onclick="selectCountry(this)">Britain</div></div>
        <button id="connect" type="button" onclick="finishCountry()">\(repeatStage ? "Continue" : "Connect")</button></form>
        <script>\(failureScript)
        var stage=0;
        function finishCountry(){
          if(choiceBox.dataset.selected!=='GB')return failSmokeTest();
          if(\(repeatStage) && stage===0){stage=1;choiceBox.dataset.selected='';choiceBox.textContent='Choose';var field=document.createElement('input');field.type='email';field.id='guestEmail';field.required=true;document.querySelector('form').appendChild(field);connect.textContent='Connect';return}
          if(\(repeatStage) && guestEmail.value!=='sarah.chen.wifi@gmail.com')return failSmokeTest();
          document.body.textContent='Connected';
        }
        function selectCountry(option){choiceBox.dataset.selected=option.dataset.value;choiceBox.textContent=option.textContent;choiceBox.setAttribute('aria-expanded','false');option.setAttribute('aria-selected','true');countries.hidden=true}
        </script>
        """
    }
}
