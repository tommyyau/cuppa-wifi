"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const autofill = require("../autofill.js");

function checkCases(fn, cases) {
  for (const [input, expected] of cases) {
    assert.equal(fn(input), expected, JSON.stringify(input));
  }
}

test("abbreviated terms consent keeps marketing precedence", () => {
  assert.equal(autofill.isConsentLabel("tnc"), true);
  assert.equal(autofill.isConsentLabel("accept_tnc"), true);
  assert.equal(autofill.isConsentLabel("tnc_marketing"), false);
  assert.equal(autofill.isConsentLabel("notncunknown"), false);
});

test("fallback correction ladder matches the shared JSON contract", () => {
  const sharedLadder = JSON.parse(
    fs.readFileSync(
      path.join(
        __dirname,
        "../correction-ladder.json"
      ),
      "utf8"
    )
  );
  assert.deepEqual(autofill.defaultCorrectionLadder, sharedLadder);
});

test("field classification uses hard signals and rendered labels", () => {
  checkCases(autofill.classifyField, [
    [{ type: "email", label: "Your login" }, "email"],
    [{ type: "tel", label: "Contact" }, "phone"],
    [{ type: "password", label: "Secret" }, "password"],
    [{ label: "Email address" }, "email"],
    [{ label: "Mobile number" }, "phone"],
    [{ label: "First Name" }, "firstName"],
    [{ label: "Surname" }, "lastName"],
    [{ label: "Full name" }, "fullName"],
    [{ label: "Postcode" }, "postcode"],
    [{ label: "Address line 1" }, "address"],
    [{ label: "Address line 2" }, "addressLine2"],
    [{ label: "Town or city" }, "city"],
    [{ label: "County" }, "county"],
    [{ label: "Country" }, "country"],
    [{ label: "Date of birth" }, "dob"],
    [{ label: "Age" }, "age"],
    [{ label: "Company" }, "company"],
    [{ label: "Occupation" }, "occupation"],
    [{ label: "Why are you visiting us today?" }, "reasonForVisit"],
    [{ label: "Are you a Santander customer?" }, "customerStatus"],
    [{ autocomplete: "address-level2", label: "Location" }, "city"],
    [{ label: "Random field xyz" }, "unknown"],
  ]);
});

test("fail-closed language is classified before any DOM work", () => {
  checkCases(autofill.detectFailClosed, [
    ["Enter your one-time verification code", "verification_code_required"],
    ["We sent an SMS code to your phone", "verification_code_required"],
    ["Please complete the CAPTCHA below", "captcha_required"],
    ["Enter your voucher code", "voucher_or_venue_credential_required"],
    ["Enter your card number to pay", "voucher_or_venue_credential_required"],
    ["Welcome to the coffee shop guest WiFi", null],
  ]);
});

test("rendered Pret branding identifies the venue", () => {
  assert.equal(
    autofill.detectVenue("Welcome to Pret", ""),
    "Pret"
  );
  assert.equal(
    autofill.detectVenue("", "Pret A Manger Wi-Fi"),
    "Pret"
  );
  assert.equal(
    autofill.detectVenue("Powered by Evolve", "Guest Wi-Fi"),
    null
  );
});

test("consent, marketing, and submit choices remain privacy-safe", () => {
  assert.equal(
    autofill.isConsentLabel("I agree to the Terms and Conditions"),
    true
  );
  assert.equal(
    autofill.isConsentLabel("I agree to receive marketing offers"),
    false
  );
  assert.equal(
    autofill.isMarketingLabel("Send marketing offers and newsletters"),
    true
  );
  checkCases(autofill.looksLikeSubmitControl, [
    [{ tagName: "BUTTON", text: "Connect to WiFi" }, true],
    [{ tagName: "BUTTON", text: "Continue" }, true],
    [{ tagName: "BUTTON", text: "Sign up" }, true],
    [{ tagName: "BUTTON", text: "Register for Wi-Fi" }, true],
    [{ tagName: "INPUT", type: "submit", text: "" }, true],
    [{ tagName: "A", text: "", title: "Continue to the Internet" }, true],
    [{ tagName: "BUTTON", text: "Cancel" }, false],
    [{ tagName: "BUTTON", text: "Go back" }, false],
  ]);
});

test("cookie overlays are rejected only through an explicit safe action", () => {
  checkCases(autofill.looksLikeCookieRejectControl, [
    [{ text: "Reject all cookies" }, true],
    [{ text: "Use necessary cookies only" }, true],
    [{ ariaLabel: "Continue without accepting" }, true],
    [{ text: "Accept all cookies" }, false],
    [{ text: "Manage cookie settings" }, false],
    [{ text: "Accept terms and conditions" }, false],
  ]);
});

test("extended persona fields resolve without venue-specific selectors", () => {
  const identity = {
    addressLine2: "Flat 2",
    county: "Greater London",
    company: "Independent",
    occupation: "Other",
    reasonForVisit: "Guest Wi-Fi access",
  };
  assert.equal(
    autofill.valueForClassification("addressLine2", identity),
    "Flat 2"
  );
  assert.equal(
    autofill.valueForClassification("county", identity),
    "Greater London"
  );
  assert.equal(
    autofill.valueForClassification("company", identity),
    "Independent"
  );
  assert.equal(
    autofill.valueForClassification("occupation", identity),
    "Other"
  );
  assert.equal(
    autofill.valueForClassification("reasonForVisit", identity),
    "Guest Wi-Fi access"
  );
  assert.equal(
    autofill.valueForClassification("customerStatus", identity),
    "No"
  );
});

// ======================================================================
// Feedback-retry loop
// ======================================================================

test("phoneVariants escalates national -> +44 -> 0044 -> stripped", () => {
  assert.deepEqual(
    autofill.phoneVariants("07700900123"),
    ["+447700900123", "00447700900123"]
  );
  assert.deepEqual(
    autofill.phoneVariants("+447700900123"),
    ["07700900123", "00447700900123"]
  );
  assert.deepEqual(
    autofill.phoneVariants("00447700900123"),
    ["07700900123", "+447700900123"]
  );
  assert.deepEqual(
    autofill.phoneVariants("077 009 001 23"),
    ["07700900123", "+447700900123", "00447700900123"]
  );
  assert.deepEqual(autofill.phoneVariants(""), []);
});

test("correction generators consume the injected shared ladder", () => {
  const custom = {
    format: 1,
    maxCorrectionRounds: 1,
    phoneFormats: ["international_00", "e164", "national", "digits"],
    postcodeFormats: ["compact_upper", "spaced_upper", "upper", "compact"],
    dateFormats: ["dd-mm-yyyy", "yyyy-mm-dd", "dd/mm/yyyy", "mm/dd/yyyy"],
  };
  autofill.configureCorrectionLadder(custom);
  assert.deepEqual(
    autofill.phoneVariants("07700900123"),
    ["00447700900123", "+447700900123"]
  );
  assert.deepEqual(
    autofill.dateVariants("1988-03-14"),
    ["14-03-1988", "14/03/1988", "03/14/1988"]
  );
  autofill.configureCorrectionLadder(null);
});

test("postcodeVariants toggles the space and tries uppercase", () => {
  assert.deepEqual(autofill.postcodeVariants("SW1A1AA"), ["SW1A 1AA"]);
  assert.deepEqual(
    autofill.postcodeVariants("sw1a 1aa"),
    ["SW1A 1AA", "SW1A1AA", "sw1a1aa"]
  );
  assert.deepEqual(autofill.postcodeVariants(""), []);
});

test("dateVariants cycles yyyy-mm-dd / dd/mm/yyyy / mm/dd/yyyy / dd-mm-yyyy", () => {
  assert.deepEqual(
    autofill.dateVariants("1988-03-14"),
    ["14/03/1988", "03/14/1988", "14-03-1988"]
  );
  assert.deepEqual(
    autofill.dateVariants("14/03/1988"),
    ["1988-03-14", "03/14/1988", "14-03-1988"]
  );
  assert.deepEqual(autofill.dateVariants("not a date"), []);
});

test("emailVariants never proposes alternate domains (identity, not formatting)", () => {
  assert.deepEqual(autofill.emailVariants("guest.wifi@mailinator.com"), []);
  assert.deepEqual(autofill.emailVariants("guest.wifi@guerrillamail.com"), []);
  assert.deepEqual(autofill.emailVariants(""), []);
});

const phoneFixture = require("./fixtures/phone-international.fixture.js");
const postcodeFixture = require("./fixtures/postcode-space.fixture.js");
const dateFixture = require("./fixtures/date-format.fixture.js");
const rejectEverythingFixture = require("./fixtures/reject-everything.fixture.js");
const notRetouchedFixture = require("./fixtures/accepted-field-not-retouched.fixture.js");
const pretContractFixture = require("./fixtures/pret-contract.fixture.js");
const costaClickthroughFixture = require("./fixtures/costa-clickthrough.fixture.js");
const midLoopOtpFixture = require("./fixtures/mid-loop-otp.fixture.js");

const FAST_TIMEOUTS = { readinessTimeoutMs: 200, transitionTimeoutMs: 60 };

test("parsed forms proceed while resources load, but incomplete documents wait", async () => {
  for (const state of ["loading", "interactive"]) {
    const { doc, identity, wasAccepted } = pretContractFixture.build();
    doc.readyState = state;
    const result = await autofill.run({ doc, identity, ...FAST_TIMEOUTS });
    assert.equal(result.status, state === "loading" ? "no_form" : "submitted");
    assert.equal(wasAccepted(), state === "interactive");
  }
});

test("five-venue contract: rendered Pret form fills, accepts terms, and declines marketing", async () => {
  const { doc, identity, fields, wasAccepted } = pretContractFixture.build();
  const result = await autofill.run({ doc, identity, ...FAST_TIMEOUTS });
  assert.equal(result.status, "submitted");
  assert.equal(wasAccepted(), true);
  assert.equal(fields.first.value, "Sarah");
  assert.equal(fields.last.value, "Chen");
  assert.equal(fields.email.value, "sarah.chen.fixture@example.com");
  assert.equal(fields.terms.checked, true);
  assert.notEqual(fields.marketing.checked, true);
});

test("Costa click-through: nearby consent is checked and image grant link clicked", async () => {
  const { doc, identity, consent, disclosure, wasAccepted } =
    costaClickthroughFixture.build();
  const result = await autofill.run({ doc, identity, ...FAST_TIMEOUTS });
  assert.equal(result.status, "submitted");
  assert.equal(wasAccepted(), true);
  assert.equal(consent.checked, true);
  assert.notEqual(disclosure.checked, true);
});

test("retry loop: national phone rejected, +44 international accepted", async () => {
  const { doc, identity, phoneInput } = phoneFixture.build();
  const result = await autofill.run({ doc, identity, ...FAST_TIMEOUTS });
  assert.equal(result.status, "submitted");
  assert.equal(phoneInput.value, "+447700900123");
});

test("retry loop: compact postcode rejected, spaced postcode accepted", async () => {
  const { doc, identity, postcodeInput } = postcodeFixture.build();
  const result = await autofill.run({ doc, identity, ...FAST_TIMEOUTS });
  assert.equal(result.status, "submitted");
  assert.equal(postcodeInput.value, "SW1A 1AA");
});

test("retry loop: ISO date rejected, dd/mm/yyyy accepted", async () => {
  const { doc, identity, dobInput } = dateFixture.build();
  const result = await autofill.run({ doc, identity, ...FAST_TIMEOUTS });
  assert.equal(result.status, "submitted");
  assert.equal(dobInput.value, "14/03/1988");
});

test("retry loop: portal that rejects everything gives up bounded with a value-free report", async () => {
  const { doc, identity, getSubmitCount } = rejectEverythingFixture.build();
  const result = await autofill.run({ doc, identity, ...FAST_TIMEOUTS });
  assert.equal(result.status, "unsupported");
  assert.ok(Array.isArray(result.detail.fieldsStillFailing));
  assert.ok(result.detail.fieldsStillFailing.length > 0);
  const intents = result.detail.fieldsStillFailing.map((f) => f.intent);
  assert.ok(intents.includes("phone"));
  assert.ok(intents.includes("postcode"));
  for (const f of result.detail.fieldsStillFailing) {
    assert.ok(f.name || f.label, "each entry names the field (schema)");
  }
  // VALUE-FREE guarantee: no submitted value — original or any correction
  // variant — may appear anywhere in the returned detail.
  const serialized = JSON.stringify(result.detail);
  assert.doesNotMatch(serialized, /07700|447700|900123|SW1A|1AA|mailinator/i);
  assert.equal(result.detail.lastValues, undefined);
  // Bounded: 1 initial submit + at most 3 correction rounds, never more.
  assert.ok(
    getSubmitCount() <= 4,
    `expected at most 4 submits (1 initial + 3 correction rounds), got ${getSubmitCount()}`
  );
});

test("retry loop: rejected email yields an actionable identity report, never a domain retry", async () => {
  const { build } = require("./fixtures/email-identity-rejected.fixture.js");
  const { doc, identity, emailInput, getSeenValues } = build();
  const result = await autofill.run({ doc, identity, ...FAST_TIMEOUTS });
  assert.equal(result.status, "unsupported");
  assert.equal(result.detail.emailIdentityRejected, true);
  const intents = result.detail.fieldsStillFailing.map((f) => f.intent);
  assert.ok(intents.includes("email"));
  // The configured address was never swapped: every submit saw the same
  // value, and the field still holds it.
  assert.equal(emailInput.value, "guest.wifi@mailinator.com");
  for (const seen of getSeenValues()) {
    assert.equal(seen, "guest.wifi@mailinator.com");
  }
  // And the report itself is value-free.
  assert.doesNotMatch(JSON.stringify(result.detail), /mailinator|guest\.wifi/i);
});

test("retry loop: an already-accepted field is never re-touched", async () => {
  const { doc, identity, phoneInput, emailInput, getEmailInputEventCount } =
    notRetouchedFixture.build();
  const result = await autofill.run({ doc, identity, ...FAST_TIMEOUTS });
  assert.equal(result.status, "submitted");
  assert.equal(phoneInput.value, "+447700900123");
  assert.equal(emailInput.value, "guest@example.com");
  // Exactly one "input" event: the initial fill. Correction rounds must
  // never re-write a field that was never flagged as rejected.
  assert.equal(getEmailInputEventCount(), 1);
});

test("retry loop: OTP revealed after a correction stops every further submit", async () => {
  const { doc, identity, getSubmitCount } = midLoopOtpFixture.build();
  const result = await autofill.run({ doc, identity, ...FAST_TIMEOUTS });
  assert.equal(result.status, "unsupported");
  assert.equal(result.detail, "sms_verification");
  assert.equal(getSubmitCount(), 2);
});

const { createDocument } = require("./fixtures/dom-shim");
const { el, button, labelFor } = require("./fixtures/build-helpers");

test("shared field descriptor corpus agrees with native portal intents", () => {
  const cases = JSON.parse(fs.readFileSync(path.join(__dirname, "../../TestFixtures/Portal/field_descriptors.json"), "utf8"));
  for (const row of cases) assert.equal(autofill.classifyFieldEvidence(row.descriptor).intent, row.intent, JSON.stringify(row.descriptor));
});

test("a rich form hidden by its ancestor is ignored", () => {
  const doc = createDocument();
  const hiddenForm = el(doc, "form", {}, [el(doc, "input", { name: "email", type: "email", required: "" }), button(doc, "Connect")]);
  doc.body.appendChild(el(doc, "div", {style: "display:none"}, [hiddenForm]));
  const visibleForm = el(doc, "form", {}, [button(doc, "Connect")]);
  doc.body.appendChild(visibleForm);
  assert.equal(autofill.chooseForm(doc), visibleForm);
});

test("marketing is declined, explicit opt-out checked, and bundled consent blocks submission", async () => {
  const doc = createDocument();
  const optIn = el(doc, "input", {type:"checkbox", id:"offers", checked:""}); optIn.checked = true;
  const optOut = el(doc, "input", {type:"checkbox", id:"optout"});
  doc.body.appendChild(el(doc, "form", {}, [labelFor(doc,"offers","Receive marketing offers"), optIn, labelFor(doc,"optout","Do not send marketing communications"), optOut, button(doc,"Connect")]));
  autofill.fillOneStep(doc, {});
  assert.equal(optIn.checked, false);
  assert.equal(optOut.checked, true);

  const blocked = createDocument();
  const email = el(blocked, "input", {type: "email", required: ""});
  const bundled = el(blocked, "input", {type: "checkbox", id: "terms", required: ""});
  const action = button(blocked, "Connect");
  let writes = 0, clicks = 0;
  // Native value assignment calls the prototype setter, which writes the shim's
  // backing store. Observe that store without masking the public value getter.
  for (const [field, property] of [[email, "_value"], [bundled, "checked"]]) {
    let value = field[property];
    Object.defineProperty(field, property, {
      get: () => value,
      set: (next) => { writes++; value = next; },
      configurable: true,
    });
  }
  action.addEventListener("click", () => clicks++);
  blocked.body.appendChild(el(blocked, "form", {}, [
    email,
    labelFor(blocked, "terms", "I accept the Wi-Fi terms and agree to receive promotional emails"),
    bundled,
    action,
  ]));
  const result = await autofill.run({doc: blocked, identity: {email: "guest@example.test"}, ...FAST_TIMEOUTS});
  assert.equal(result.status, "unsupported");
  assert.equal(result.detail, "marketing_consent_required");
  assert.equal(bundled.checked, false);
  assert.equal(email.value, "");
  assert.equal(writes, 0);
  assert.equal(clicks, 0);
  assert.equal(result.journey.actions, 0);
});

test("required unknown fields stop before clicking", async () => {
  const doc = createDocument(); let clicks = 0;
  const action = button(doc, "Connect"); action.addEventListener("click", ()=>clicks++);
  doc.body.appendChild(el(doc,"form",{},[el(doc,"input",{name:"referenceXYZ",required:""}),action]));
  const result = await autofill.run({doc,identity:{},...FAST_TIMEOUTS});
  assert.equal(result.status,"needs_more"); assert.equal(clicks,0);
});

test("optional OTP and paid copy do not block free registration", async () => {
  const doc = createDocument();
  doc.body.appendChild(el(doc,"p",{},["Premium users can pay or use a verification code"]));
  const action = button(doc,"Connect"); action.addEventListener("click",()=> {while(doc.body.childNodes.length) doc.body.removeChild(doc.body.childNodes[0]);});
  doc.body.appendChild(el(doc,"form",{},[el(doc,"input",{type:"email",name:"email",required:""}),el(doc,"input",{name:"verification_code"}),action]));
  const result = await autofill.run({doc,identity:{email:"guest@example.com"},...FAST_TIMEOUTS});
  assert.equal(result.status,"submitted");
});

test("same form and button can reveal a different stage", async () => {
  const doc = createDocument(); let clicks = 0;
  const input = el(doc,"input",{name:"firstName",required:""});
  const action = button(doc,"Continue");
  const form = el(doc,"form",{},[input,action]); doc.body.appendChild(form);
  action.addEventListener("click",()=>{ clicks++; if(clicks===1){ input.setAttribute("name","email"); input.setAttribute("type","email"); input.value=""; }else{doc.body.removeChild(form);} });
  const result = await autofill.run({doc,identity:{firstName:"Guest",email:"guest@example.com"},...FAST_TIMEOUTS});
  assert.equal(result.status,"submitted"); assert.equal(clicks,2); assert.equal(result.journey.actions,2);
  assert.notEqual(result.trace[0].signature,result.trace[1].signature);
});

test("journey action budget also counts correction submissions", async () => {
  const {doc,identity,getSubmitCount}=rejectEverythingFixture.build();
  const result=await autofill.run({doc,identity,maxSteps:2,...FAST_TIMEOUTS});
  assert.equal(result.status,"unsupported"); assert.equal(result.journey.actions,2); assert.equal(getSubmitCount(),2);
});

test("an optional account password does not block guest email registration", () => {
  const doc = createDocument();
  const form=el(doc,"form",{},[el(doc,"input",{name:"email",type:"email",required:""}),el(doc,"input",{type:"password",autocomplete:"current-password"}),button(doc,"Free guest Wi-Fi")]);
  doc.body.appendChild(form);
  assert.equal(autofill.workflowGate(doc,form),null);
});

const { option } = require('./fixtures/build-helpers');

function localFixture(label = 'Prénom') {
  const doc = createDocument();
  const input = el(doc,'input',{id:'opaque',required:''});
  const action = button(doc,'Connect',{type:'button'});
  let clicks = 0;
  const form = el(doc,'form',{},[labelFor(doc,'opaque',label),input,action]);
  doc.body.appendChild(form);
  action.addEventListener('click',()=>{clicks++;doc.body.removeChild(form);});
  return {doc,input,action,form,getClicks:()=>clicks};
}

test('error and search pages stop before identity filling, local reasoning or navigation', async()=>{
  for (const title of ['Page Not Found - Example','Search our website']) {
    const doc=createDocument();doc.title=title;
    const input=el(doc,'input',{type:'search',name:'s'});
    const action=button(doc,'Search',{type:'submit'});let clicks=0,requests=0;
    action.addEventListener('click',()=>clicks++);
    doc.body.appendChild(el(doc,'form',{role:'search'},[input,action]));
    const register=el(doc,'a',{href:'/signup'},[]);register.textContent='Register';
    register.addEventListener('click',()=>clicks++);doc.body.appendChild(register);
    const result=await autofill.run({doc,identity:{email:'guest@example.com'},...FAST_TIMEOUTS,
      reasoner:async()=>{requests++;return {choice:'a0'}}});
    assert.equal(result.status,'unsupported');assert.equal(result.detail,'portal_page_unavailable');
    assert.equal(input.value,'');assert.equal(clicks,0);assert.equal(requests,0);
  }
});

test('a website search sidebar is skipped while the actual portal form completes',async()=>{
  const f=localFixture('First name');
  const search=el(f.doc,'input',{type:'search',name:'s'});const action=button(f.doc,'Search');
  let searches=0;action.addEventListener('click',()=>searches++);
  f.doc.body.appendChild(el(f.doc,'form',{role:'search'},[search,action]));
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Guest'},...FAST_TIMEOUTS});
  assert.equal(f.input.value,'Guest');assert.equal(f.getClicks(),1);assert.equal(searches,0);assert.equal(search.value,'');
  assert.equal(result.status,'submitted');
});

test('country aliases inspect both visible label and submitted value',()=>{
  const doc=createDocument();
  const country=el(doc,'select',{name:'country',required:''},[option(doc,'','Choose'),option(doc,'GB','Britain'),option(doc,'FR','France')]);
  doc.body.appendChild(el(doc,'form',{},[country,button(doc,'Connect')]));
  const result=autofill.fillOneStep(doc,{country:'United Kingdom'});
  assert.equal(country.value,'GB'); assert.deepEqual(result.unresolved,[]);
});

test('visible month names override zero based option values',()=>{
  const doc=createDocument();
  const month=el(doc,'select',{name:'dobMonth',required:''},['January','February','March','April'].map((m,i)=>option(doc,String(i),m)));
  doc.body.appendChild(el(doc,'form',{},[month,button(doc,'Connect')]));
  autofill.fillOneStep(doc,{dob:'1988-03-14'});
  assert.equal(month.value,'2');
});

test('conditional required controls are refilled before continuation',async()=>{
  const doc=createDocument(); const email=el(doc,'input',{type:'email',required:''});
  const phone=el(doc,'input',{type:'tel',required:''}); const action=button(doc,'Continue',{type:'button',disabled:''});
  const form=el(doc,'form',{},[email,action]);doc.body.appendChild(form);
  email.addEventListener('input',()=>{if(!phone.parentNode)form.appendChild(phone)});
  phone.addEventListener('input',()=>action.removeAttribute('disabled'));
  action.addEventListener('click',()=>{assert.equal(phone.value,'07700900123');doc.body.removeChild(form)});
  const result=await autofill.run({doc,identity:{email:'guest@example.com',phone:'07700900123'},...FAST_TIMEOUTS});
  assert.equal(result.status,'submitted');
});

test('local classifier uses saved identity without receiving entered values',async()=>{
  const f=localFixture(); f.input.value='private-existing-value'; let received;
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah',email:'private@example.com'},...FAST_TIMEOUTS,reasoner:async request=>{
    received=request;return {fields:[{key:'f0',intent:'first_name'}]};
  }});
  assert.equal(result.status,'submitted');assert.equal(f.input.value,'Sarah');assert.equal(f.getClicks(),1);
  assert.doesNotMatch(JSON.stringify(received),/private-existing-value|private@example.com|Sarah/);
  assert.equal(received.fields[0].label,'Prénom');
});

test('changed labels invalidate a pending local decision',async()=>{
  const f=localFixture();
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah'},...FAST_TIMEOUTS,reasoner:async()=>{
    f.doc.querySelector('label').textContent='An unexplained different field';return {fields:[{key:'f0',intent:'first_name'}]};
  }});
  assert.equal(result.status,'needs_more');assert.equal(f.input.value,'');assert.equal(f.getClicks(),0);
});

test('invented, duplicate and credential field decisions are rejected',async()=>{
  for(const fields of [[{key:'f999',intent:'first_name'}],[{key:'f0',intent:'password'}],[{key:'f0',intent:'first_name'},{key:'f0',intent:'email'}]]){
    const f=localFixture();
    const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah',password:'secret'},...FAST_TIMEOUTS,reasoner:async()=>({fields})});
    assert.equal(result.status,'needs_more');assert.equal(f.input.value,'');assert.equal(f.getClicks(),0);
  }
});

test('failed local model retains deterministic filling and assistance',async()=>{
  const f=localFixture();
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah'},...FAST_TIMEOUTS,reasoner:async()=>{throw Error('model unavailable')}});
  assert.equal(result.status,'needs_more');assert.equal(f.getClicks(),0);
  const doc=createDocument();const action=button(doc,'Connect',{type:'button'});
  const form=el(doc,'form',{},[el(doc,'input',{type:'email',required:''}),action]);doc.body.appendChild(form);
  action.addEventListener('click',()=>doc.body.removeChild(form));
  let calls=0;const good=await autofill.run({doc,identity:{email:'guest@example.com'},...FAST_TIMEOUTS,reasoner:async()=>{calls++;throw Error('unavailable')}});
  assert.equal(good.status,'submitted');assert.equal(calls,0);
});

test('an ordinary submit button remains usable when the model would abstain',async()=>{
  const doc=createDocument();const action=button(doc,'→',{type:'submit'});
  const email=el(doc,'input',{type:'email',required:''});
  const form=el(doc,'form',{},[email,action]);doc.body.appendChild(form);
  let calls=0;action.addEventListener('click',()=>doc.body.removeChild(form));
  const result=await autofill.run({doc,identity:{email:'guest@example.com'},...FAST_TIMEOUTS,reasoner:async()=>{calls++;return {fields:[]}}});
  assert.equal(email.value,'guest@example.com');assert.equal(result.status,'submitted');assert.equal(calls,0);
});

test('locally identified verification digits are never filled or submitted',async()=>{
  const f=localFixture('Saisissez les six chiffres reçus par courriel');f.input.setAttribute('type','number');
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah'},...FAST_TIMEOUTS,reasoner:async()=>({fields:[{key:'f0',intent:'verification_code'}]})});
  assert.equal(result.status,'unsupported');assert.equal(result.detail,'verification_code_required');assert.equal(f.input.value,'');assert.equal(f.getClicks(),0);
});

test('unfamiliar month options keep the model-selected submitted value',async()=>{
  const doc=createDocument();const month=el(doc,'select',{name:'dobMonth',required:''},[option(doc,'','Choose'),option(doc,'0','Janvier'),option(doc,'2','Mars'),option(doc,'3','Avril')]);
  const action=button(doc,'Connect',{type:'button'});const form=el(doc,'form',{},[month,action]);doc.body.appendChild(form);
  action.addEventListener('click',()=>doc.body.removeChild(form));
  const result=await autofill.run({doc,identity:{dob:'1988-03-14'},...FAST_TIMEOUTS,reasoner:async request=>{
    assert.equal(request.mode,'choice');assert.equal(request.target,'march');assert.equal(request.choices[1].value,'2');return {fields:[],choice:'o1'};
  }});
  assert.equal(month.value,'2');assert.equal(result.status,'submitted');
});

test('local actions can advance unfamiliar controls but cannot invent IDs',async()=>{
  for(const choice of ['a0','a99']){
    const doc=createDocument();const action=button(doc,'Proceed',{type:'button'});const form=el(doc,'form',{},[action]);doc.body.appendChild(form);let clicks=0;
    action.addEventListener('click',()=>{clicks++;doc.body.removeChild(form)});
    const result=await autofill.run({doc,...FAST_TIMEOUTS,reasoner:async request=>{assert.equal(request.mode,'action');return {fields:[],choice}}});
    assert.equal(clicks,choice==='a0'?1:0);assert.equal(result.status,choice==='a0'?'submitted':'no_form');
  }
});

test('irrelevant and paid actions are excluded before local reasoning',async()=>{
  const doc=createDocument();let clicks=0;let requestSeen;
  for(const name of ['Buy premium','Help','Privacy policy','Continue with Apple','Proceed']){
    const action=button(doc,name,{type:'button'});action.addEventListener('click',()=>clicks++);doc.body.appendChild(action);
  }
  const result=await autofill.run({doc,...FAST_TIMEOUTS,reasoner:async request=>{requestSeen=request;return {fields:[]}}});
  assert.deepEqual(requestSeen.choices.map(c=>c.label),['Proceed']);assert.equal(clicks,0);assert.equal(result.status,'no_form');
});

test('unresponsive local inference respects the attempt deadline',async()=>{
  const f=localFixture();const started=Date.now();
  const result=await autofill.run({doc:f.doc,...FAST_TIMEOUTS,deadline:started+80,reasoner:()=>new Promise(()=>{})});
  assert.equal(f.getClicks(),0);assert.notEqual(result.status,'submitted');assert.ok(Date.now()-started<500);
});

test('local action retries stay within the multi-stage action budget',async()=>{
  const doc=createDocument();let calls=0;let stages=0;
  function render(){
    doc.body.textContent='';
    const action=button(doc,'Proceed '+stages,{type:'button'});
    action.addEventListener('click',()=>{stages++;render()});doc.body.appendChild(action);
  }
  render();
  const result=await autofill.run({doc,...FAST_TIMEOUTS,maxSteps:8,reasoner:async()=>{calls++;return {fields:[],choice:'a0'}}});
  assert.equal(calls,8);assert.equal(stages,8);assert.equal(result.journey.actions,8);assert.notEqual(result.status,'submitted');
});

test('ambiguity gets an independent translation and comparison before submitting',async()=>{
  const f=localFixture('Contact identity');const strategies=[];
  f.input.addEventListener('input',()=>assert.notEqual(f.input.value,'1 Example Street'));
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah',lastName:'Chen',address:'1 Example Street'},...FAST_TIMEOUTS,reasoner:async request=>{
    strategies.push(request.review.strategy);
    assert.doesNotMatch(JSON.stringify(request),/Sarah|Chen|Example Street/);
    return {fields:[{key:'f0',intent:request.review.strategy === 'read' ? 'address_line_1' : 'full_name'}]};
  }});
  assert.deepEqual(strategies,['read','translate','compare']);assert.equal(f.input.value,'Sarah Chen');
  assert.equal(result.status,'submitted');assert.equal(f.getClicks(),1);
});

test('a generic word in a linked description is reviewed before a guessed address is written',async()=>{
  const f=localFixture('Guest details');const strategies=[];
  f.form.appendChild(el(f.doc,'span',{id:'explanation'},['Please address this greeting: nombre completo.']));
  f.input.setAttribute('aria-describedby','explanation');
  f.input.addEventListener('input',()=>assert.notEqual(f.input.value,'1 Example Street'));
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah',lastName:'Chen',address:'1 Example Street'},...FAST_TIMEOUTS,reasoner:async request=>{
    strategies.push(request.review.strategy);return {fields:[{key:'f0',intent:request.review.strategy === 'read' ? 'address_line_1' : 'full_name'}]};
  }});
  assert.deepEqual(strategies,['read','translate','compare']);assert.equal(f.input.value,'Sarah Chen');assert.equal(result.status,'submitted');assert.equal(f.getClicks(),1);
  assert.equal(autofill.classifyField({label:'Guest details',description:'House number and street address'}),'address');
  assert.equal(autofill.classifyField({label:'Your address'}),'address');
  assert.equal(autofill.classifyField({label:'Contact destination'}),'unknown');
  for(const name of ['countryName','countryOfResidence','contact_country','nationalitycode'])assert.equal(autofill.classifyField({name}),'country');
});

test('clear access terms and marketing choices do not spend local model requests',async()=>{
  const f=localFixture('Email address');f.input.setAttribute('type','email');
  const terms=el(f.doc,'input',{id:'terms',type:'checkbox',required:''});
  const offers=el(f.doc,'input',{id:'offers',type:'checkbox',checked:true});
  f.form.appendChild(labelFor(f.doc,'terms','I accept the Wi-Fi terms'));f.form.appendChild(terms);
  f.form.appendChild(labelFor(f.doc,'offers','Receive marketing offers'));f.form.appendChild(offers);
  const result=await autofill.run({doc:f.doc,identity:{email:'guest@example.com'},...FAST_TIMEOUTS,reasoner:async()=>assert.fail('Clear controls must not invoke the model')});
  assert.equal(result.status,'submitted');assert.equal(terms.checked,true);assert.equal(offers.checked,false);
});

test('translated wording checks a mistaken name category without filling generated text',async()=>{
  for(const [target,translation,wrong,value,description] of [['full_name','Your details','first_name','Sarah Chen','How should we address you: your complete name.'],['first_name','Your first name only','full_name','Sarah','']]) {
    const f=localFixture('Contact identity');let calls=0;
    const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah',lastName:'Chen'},...FAST_TIMEOUTS,reasoner:async request=>{
      calls++;return {fields:[{key:'f0',intent:calls === 1 ? target : wrong,translation:calls === 1 ? undefined : translation,translatedDescription:calls === 1 ? undefined : description}]};
    }});
    assert.equal(calls,2);assert.equal(f.input.value,value);assert.equal(f.getClicks(),1);assert.equal(result.status,'submitted');
  }
});

test('a generic name translation cannot resolve a conflicting specific name category',async()=>{
  const f=localFixture('Contact identity');let calls=0;
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah',lastName:'Chen'},...FAST_TIMEOUTS,reasoner:async request=>{
    calls++;return {fields:[{key:'f0',intent:'first_name',translation:request.review.strategy === 'read' ? undefined : 'Name'}]};
  }});
  assert.equal(calls,3);assert.equal(f.input.value,'');assert.equal(f.getClicks(),0);assert.equal(result.status,'needs_more');
});

test('ambiguous translated words do not overrule two agreeing semantic interpretations',async()=>{
  const f=localFixture('Guest details');let calls=0;
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah',lastName:'Chen'},...FAST_TIMEOUTS,reasoner:async request=>{
    calls++;return {fields:[{key:'f0',intent:'full_name',translation:request.review.strategy === 'read' ? undefined : 'Guest details',translatedDescription:'Please address our greeting: nom complet.'}]};
  }});
  assert.equal(calls,2);assert.equal(f.input.value,'Sarah Chen');assert.equal(f.getClicks(),1);assert.equal(result.status,'submitted');
});

test('a translated issued credential is not reinterpreted as a name',async()=>{
  const f=localFixture('Contact identity');let calls=0;
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah'},...FAST_TIMEOUTS,reasoner:async request=>{
    calls++;return {fields:[{key:'f0',intent:'first_name',translation:request.review.strategy === 'read' ? undefined : 'Existing membership number'}]};
  }});
  assert.equal(calls,3);assert.equal(f.input.value,'');assert.equal(f.getClicks(),0);assert.equal(result.status,'needs_more');
});

test('abstention and a failed response can recover on later interpretation passes',async()=>{
  for (const first of [null,{fields:[{key:'f0',intent:'unknown'}]}]) {
    const f=localFixture('Contact identity');let calls=0;
    const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah'},...FAST_TIMEOUTS,reasoner:async request=>{
      calls++;return calls === 1 ? first : {fields:[{key:'f0',intent:'first_name'}]};
    }});
    assert.equal(calls,3);assert.equal(f.input.value,'Sarah');assert.equal(result.status,'submitted');
  }
});

test('three inconclusive interpretations stop before writing or submitting',async()=>{
  const f=localFixture('Contact identity');const strategies=[];
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah'},...FAST_TIMEOUTS,reasoner:async request=>{
    strategies.push(request.review.strategy);return {fields:[{key:'f0',intent:'unknown'}]};
  }});
  assert.deepEqual(strategies,['read','translate','compare']);assert.equal(f.input.value,'');
  assert.equal(f.getClicks(),0);assert.equal(result.status,'needs_more');
});

test('comparison preserves an abstention instead of presenting only an unsupported guess',async()=>{
  const f=localFixture('Additional required information');let calls=0;
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah',lastName:'Chen'},...FAST_TIMEOUTS,reasoner:async request=>{
    calls++;
    if(request.review.strategy === 'compare')assert.deepEqual(request.review.alternatives,['full_name','unknown']);
    return {fields:[{key:'f0',intent:calls === 1 ? 'full_name' : 'unknown'}]};
  }});
  assert.equal(calls,3);assert.equal(f.input.value,'');assert.equal(f.getClicks(),0);assert.equal(result.status,'needs_more');
});

test('unspecified identifiers stop before model guesses while described identity details still fill',async()=>{
  for(const label of ['Additional mandatory identifier','Guest reference','Identification']) {
    const f=localFixture(label);let calls=0;
    const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah',lastName:'Chen'},...FAST_TIMEOUTS,reasoner:async()=>{
      calls++;return {fields:[{key:'f0',intent:'full_name'}]};
    }});
    assert.equal(calls,0);assert.equal(f.input.value,'');assert.equal(f.getClicks(),0);
    assert.equal(result.status,'unsupported');assert.equal(result.detail,'unknown_required_field');
  }
  const f=localFixture('Identification: first and last name');
  const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah',lastName:'Chen'},...FAST_TIMEOUTS});
  assert.equal(f.input.value,'Sarah Chen');assert.equal(result.status,'submitted');
  const described=localFixture('Guest identifier');let calls=0;
  described.form.appendChild(el(described.doc,'span',{id:'explanation'},['Nome e cognome']));
  described.input.setAttribute('aria-describedby','explanation');
  const reviewed=await autofill.run({doc:described.doc,identity:{firstName:'Sarah',lastName:'Chen'},...FAST_TIMEOUTS,reasoner:async request=>{
    calls++;assert.match(request.fields[0].description,/Nome e cognome/);return {fields:[{key:'f0',intent:'full_name'}]};
  }});
  assert.equal(calls,2);assert.equal(described.input.value,'Sarah Chen');assert.equal(reviewed.status,'submitted');
});

test('interpretation quota is shared across ambiguous fields',async()=>{
  const doc=createDocument();const fields=[];
  for(let i=0;i<6;i++)fields.push(labelFor(doc,'x'+i,'Unexplained entry '+i),el(doc,'input',{id:'x'+i,required:''}));
  let clicks=0,calls=0;const action=button(doc,'Connect',{type:'button'});action.addEventListener('click',()=>clicks++);
  doc.body.appendChild(el(doc,'form',{},fields.concat(action)));
  const result=await autofill.run({doc,identity:{firstName:'Sarah'},...FAST_TIMEOUTS,reasoner:async()=>{calls++;return {fields:[{key:'f0',intent:'unknown'}]}}});
  assert.equal(calls,12);assert.equal(clicks,0);assert.equal(result.status,'needs_more');
});

test('a rejected model meaning gets one bounded reconsideration without touching accepted fields',async()=>{
  const doc=createDocument(),input=el(doc,'input',{id:'opaque',required:''});
  const email=el(doc,'input',{type:'email',required:''});let emailWrites=0,clicks=0;
  email.addEventListener('input',()=>emailWrites++);
  const action=button(doc,'Connect',{type:'button'});
  const form=el(doc,'form',{},[labelFor(doc,'opaque','Contact identity'),input,email,action]);doc.body.appendChild(form);
  action.addEventListener('click',()=>{
    clicks++;if(input.value==='Sarah Chen')doc.body.removeChild(form);else input.setAttribute('aria-invalid','true');
  });
  const reviews=[];
  const result=await autofill.run({doc,identity:{firstName:'Sarah',lastName:'Chen',address:'1 Example Street',email:'guest@example.com'},...FAST_TIMEOUTS,reasoner:async request=>{
    reviews.push(request.review);
    assert.doesNotMatch(JSON.stringify(request),/Sarah|Chen|Example Street|guest@example/);
    return {fields:[{key:'f0',intent:request.review.rejected ? 'full_name' : 'address_line_1'}]};
  }});
  assert.equal(result.status,'submitted');assert.equal(clicks,2);assert.equal(emailWrites,1);
  assert.deepEqual(reviews.map(r=>r.strategy),['read','translate','compare']);assert.equal(reviews[2].rejected,true);
  assert.equal(reviews[2].previousIntent,'address_line_1');assert.equal(result.journey.actions,2);
});

test('inconclusive reconsideration clears its own rejected guess and stops further submissions',async()=>{
  const doc=createDocument(),input=el(doc,'input',{id:'opaque',required:''});let clicks=0,calls=0;
  const action=button(doc,'Connect',{type:'button'});
  doc.body.appendChild(el(doc,'form',{},[labelFor(doc,'opaque','Contact identity'),input,action]));
  action.addEventListener('click',()=>{clicks++;input.setAttribute('aria-invalid','true')});
  const result=await autofill.run({doc,identity:{firstName:'Sarah'},...FAST_TIMEOUTS,reasoner:async request=>{
    calls++;return {fields:[{key:'f0',intent:request.review.rejected ? 'unknown' : 'first_name'}]};
  }});
  assert.equal(calls,3);assert.equal(clicks,1);assert.equal(input.value,'');assert.equal(result.status,'needs_more');
});

test('model advice cannot fill textual details into a numeric control',async()=>{
  const f=localFixture('E-mail');f.input.setAttribute('type','number');let calls=0;
  const result=await autofill.run({doc:f.doc,identity:{email:'guest@example.com'},...FAST_TIMEOUTS,reasoner:async()=>{
    calls++;return {fields:[{key:'f0',intent:'email'}]};
  }});
  assert.equal(calls,3);assert.equal(f.input.value,'');assert.equal(f.getClicks(),0);assert.equal(result.status,'needs_more');
});

test('optional unfamiliar marketing is classified and declined before submission',async()=>{
  const f=localFixture('Email address');f.input.setAttribute('type','email');
  const consent=el(f.doc,'input',{id:'optional',type:'checkbox'});consent.checked=true;
  f.form.appendChild(labelFor(f.doc,'optional',"Recevoir notre lettre d'information"));f.form.appendChild(consent);
  const result=await autofill.run({doc:f.doc,identity:{email:'guest@example.com'},...FAST_TIMEOUTS,reasoner:async request=>{
    assert.equal(request.mode,'fields');assert.equal(request.fields[0].type,'checkbox');return {fields:[{key:'f0',intent:'marketing_opt_in'}]};
  }});
  assert.equal(result.status,'submitted');assert.equal(consent.checked,false);
});

test('reservation fields are gated before classification or filling',async()=>{
  for(const label of ['Reservation number','Référence de réservation','Reservierung','Personal reference issued at reception','Assigned guest identifier','Reference provided by the front desk']){
    const f=localFixture(label);let calls=0;
    const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah'},...FAST_TIMEOUTS,reasoner:async()=>{calls++;return {fields:[{key:'f0',intent:'first_name'}]}}});
    assert.equal(result.status,'unsupported');assert.equal(result.detail,'voucher_or_venue_credential_required');assert.equal(f.input.value,'');assert.equal(f.getClicks(),0);assert.equal(calls,0);
  }
});

test('an empty required option cannot be treated as a country selection',()=>{
  const doc=createDocument();const select=el(doc,'select',{name:'country',required:''},[option(doc,'','Britain'),option(doc,'FR','France')]);
  doc.body.appendChild(el(doc,'form',{},[select,button(doc,'Connect')]));
  const filled=autofill.fillOneStep(doc,{country:'United Kingdom'});
  assert.equal(select.value,'');assert.equal(filled.unresolved.length,1);
});

test('required issued identifiers stop before any model request, write or action',async()=>{
  for(const label of ['Your existing membership number','Customer ID','Loyalty number']){
    const f=localFixture(label);let calls=0;
    const result=await autofill.run({doc:f.doc,identity:{firstName:'Sarah'},...FAST_TIMEOUTS,reasoner:async()=>{calls++;return {fields:[{key:'f0',intent:'first_name'}]}}});
    assert.equal(result.status,'unsupported');assert.equal(result.detail,'unknown_required_field');assert.equal(f.input.value,'');assert.equal(f.getClicks(),0);assert.equal(calls,0);
  }
});


test('semantic conflicts are reviewable but native types stay authoritative', () => {
  assert.equal(autofill.classifyField({description:'Surname and given name',label:'Your details'}),'fullName');
  assert.equal(autofill.classifyField({label:'Electronic mail address'}),'email');
  for(const part of ['day','month','year'])assert.equal(autofill.classifyField({label:part,fieldset:'Date of birth'}),'birth_'+part);
  assert.equal(autofill.classifyFieldEvidence({label:'Email or telephone'}).evidence,'conflict');
  assert.equal(autofill.classifyFieldEvidence({name:'email',label:'Telephone'}).evidence,'conflict');
  assert.equal(autofill.classifyField({name:'email',label:'Telephone',type:'email'}),'email');
});

test('explicit credentials preserve the chosen username and never enter model observations', async () => {
  const doc=createDocument();let clicks=0;const user=el(doc,'input',{name:'username',autocomplete:'username',required:''});
  const secret=el(doc,'input',{type:'password',name:'password',autocomplete:'current-password',required:''});
  const action=button(doc,'Connect');const form=el(doc,'form',{},[user,secret,action]);doc.body.appendChild(form);
  action.addEventListener('click',()=>{clicks++;doc.body.removeChild(form)});
  const result=await autofill.run({doc,identity:{email:'persona@example.com'},credentials:{operation:'existing',username:'chosen.login',password:'Chosen-secret!'},...FAST_TIMEOUTS,reasoner:async request=>{assert.doesNotMatch(JSON.stringify(request),/chosen.login|Chosen-secret/);return null}});
  assert.equal(user.value,'chosen.login');assert.equal(secret.value,'Chosen-secret!');assert.equal(clicks,1);assert.equal(result.status,'submitted');
  assert.doesNotMatch(JSON.stringify(result),/chosen.login|Chosen-secret/);
});

test('signup wins over returning-user login and reuses the new account through activation', async () => {
  const doc=createDocument();
  const identity={firstName:'Sarah',lastName:'Chen',email:'guest@example.com',password:'Signup-test-secret!'};
  const loginEmail=el(doc,'input',{name:'email',type:'email',required:''});
  const loginPassword=el(doc,'input',{name:'password',type:'password'});
  const login=el(doc,'form',{id:'sign_in_form',action:'/login'},[loginEmail,loginPassword,button(doc,'Sign In')]);
  doc.body.appendChild(login);
  const name=el(doc,'input',{id:'user_name',name:'user[name]'});
  const email=el(doc,'input',{id:'signup_email',name:'user[email]'}),again=el(doc,'input',{id:'signup_email_again',name:'user[email_confirmation]'});
  const password=el(doc,'input',{name:'user[password]',type:'password'}),confirm=el(doc,'input',{name:'user[password_confirmation]',type:'password'});
  const create=button(doc,'Create new account');
  const signup=el(doc,'form',{id:'create_account_form',action:'/signup',hidden:''},[
    labelFor(doc,'user_name','NAME'),name,labelFor(doc,'signup_email','EMAIL'),email,labelFor(doc,'signup_email_again','EMAIL (AGAIN)'),again,password,confirm,create]);
  doc.body.appendChild(signup);
  const branch=el(doc,'a',{href:'#'},['Create an account']);doc.body.appendChild(branch);
  let requests=0,created=false,loggedIn=false;
  branch.addEventListener('click',()=>{assert.equal(loginPassword.value,'');login.setAttribute('hidden','');signup.removeAttribute('hidden');branch.setAttribute('hidden','')});
  create.addEventListener('click',()=>{
    assert.equal(name.value,'Sarah Chen');assert.equal(email.value,identity.email);assert.equal(again.value,email.value);
    assert.equal(password.value,identity.password);assert.equal(confirm.value,password.value);
    created=true;signup.setAttribute('hidden','');login.removeAttribute('hidden');
  });
  login.querySelector('button').addEventListener('click',()=>{
    assert.equal(created,true);assert.equal(loginEmail.value,email.value);assert.equal(loginPassword.value,password.value);
    loggedIn=true;doc.body.removeChild(login);doc.body.removeChild(signup);doc.body.removeChild(branch);
  });
  const result=await autofill.run({doc,identity,...FAST_TIMEOUTS,reasoner:async request=>{
    requests++;assert.equal(request.mode,'fields');assert.equal(request.fields[0].label,'NAME');
    assert.equal(request.review.alternatives.includes('username'),false);
    assert.doesNotMatch(JSON.stringify(request),/Signup-test-secret|guest@example.com/);
    return {fields:[{key:'f0',intent:'full_name',translation:'Full name'}]};
  }});
  assert.equal(result.status,'submitted');assert.equal(loggedIn,true);assert.equal(result.journey.actions,3);assert.equal(requests,2);
});

test('an ambiguous field lacking required cannot silently submit an incomplete registration', async () => {
  const doc=createDocument(),name=el(doc,'input',{id:'user_name',name:'user[name]'}),submit=button(doc,'Create new account');
  const form=el(doc,'form',{action:'/signup'},[labelFor(doc,'user_name','NAME'),name,submit]);doc.body.appendChild(form);
  let clicks=0;submit.addEventListener('click',()=>clicks++);
  const result=await autofill.run({doc,identity:{firstName:'Sarah',lastName:'Chen'},...FAST_TIMEOUTS,reasoner:async()=>({fields:[{key:'f0',intent:'unknown'}]})});
  assert.equal(result.status,'needs_more');assert.equal(clicks,0);assert.equal(name.value,'');
});

test('remembered account signs in without taking the visible registration branch', async () => {
  const doc=createDocument(),email=el(doc,'input',{type:'email'}),password=el(doc,'input',{type:'password'});
  const submit=button(doc,'Sign In'),form=el(doc,'form',{action:'/login'},[email,password,submit]);
  const branch=el(doc,'a',{href:'#'},['Create an account']);doc.body.appendChild(form);doc.body.appendChild(branch);
  branch.addEventListener('click',()=>assert.fail('Returning account must not register again'));
  submit.addEventListener('click',()=>{assert.equal(email.value,'saved@example.com');assert.equal(password.value,'Saved-secret!');doc.body.removeChild(form);doc.body.removeChild(branch)});
  const result=await autofill.run({doc,identity:{email:'changed@example.com',password:'Different-secret!'},
    credentials:{operation:'existing',username:'saved@example.com',password:'Saved-secret!'},...FAST_TIMEOUTS});
  assert.equal(result.status,'submitted');assert.equal(result.journey.actions,1);
});

for (const decision of ['login', 'abstain']) {
  test('known account with unfamiliar login control: '+decision, async () => {
    const doc=createDocument(),email=el(doc,'input',{type:'email',autocomplete:'email'});
    const password=el(doc,'input',{type:'password',autocomplete:'current-password',required:''});
    const submit=button(doc,'Accéder à mon espace',{type:'button'});
    const form=el(doc,'form',{action:'/login'},[email,password,submit]);doc.body.appendChild(form);
    const create=el(doc,'a',{href:'#'},['Create an account']);doc.body.appendChild(create);
    create.addEventListener('click',()=>assert.fail('Known account must not take registration'));
    let loginCount=0,calls=0;
    submit.addEventListener('click',()=>{loginCount++;assert.equal(email.value,'remembered@example.com');assert.equal(password.value,'Saved-secret!');doc.body.removeChild(form);doc.body.removeChild(create)});
    const result=await autofill.run({doc,...FAST_TIMEOUTS,credentials:{operation:'existing',username:'remembered@example.com',password:'Saved-secret!'},reasoner:async request=>{
      calls++;assert.equal(request.mode,'action');assert.equal(request.accountOperation,'existing');
      assert.match(request.target,/do not register/);assert.deepEqual(request.choices.map(c=>c.label),['Accéder à mon espace']);
      assert.doesNotMatch(JSON.stringify(request),/remembered@example.com|Saved-secret/);
      return decision === 'login' ? {choice:request.choices[0].key} : {fields:[]};
    }});
    assert.equal(calls,1);assert.equal(loginCount,decision==='login' ? 1 : 0);
    assert.equal(result.status,decision==='login' ? 'submitted' : 'no_form');
  });
}

for (const rejection of ['Email has already been taken', 'This email address is already registered', 'Email is invalid']) {
  test('registration feedback: '+rejection, async () => {
    const doc=createDocument(),identity={email:'guest@example.com',password:'Existing-secret!'};
    const email=el(doc,'input',{type:'email'}),password=el(doc,'input',{type:'password',autocomplete:'new-password'});
    const create=button(doc,'Create account'),signup=el(doc,'form',{action:'/signup'},[email,password,create]);
    const loginEmail=el(doc,'input',{type:'email'}),loginPassword=el(doc,'input',{type:'password'});
    const submit=button(doc,'Sign In'),login=el(doc,'form',{action:'/login',hidden:''},[loginEmail,loginPassword,submit]);
    const back=el(doc,'a',{href:'#'},['Sign in']);
    doc.body.appendChild(signup);doc.body.appendChild(login);doc.body.appendChild(back);
    let signupCount=0,loginCount=0;
    create.addEventListener('click',()=>{signupCount++;email.setAttribute('aria-invalid','true');signup.appendChild(el(doc,'p',{class:'error'},[rejection]))});
    back.addEventListener('click',()=>{signup.setAttribute('hidden','');back.setAttribute('hidden','');login.removeAttribute('hidden')});
    submit.addEventListener('click',()=>{loginCount++;assert.equal(loginEmail.value,identity.email);assert.equal(loginPassword.value,identity.password);doc.body.removeChild(signup);doc.body.removeChild(login);doc.body.removeChild(back)});
    const result=await autofill.run({doc,identity,...FAST_TIMEOUTS});
    assert.equal(signupCount,1);assert.equal(loginCount,rejection === 'Email is invalid' ? 0 : 1,JSON.stringify(result));
    assert.equal(result.status,rejection === 'Email is invalid' ? 'unsupported' : 'submitted');
    assert.doesNotMatch(JSON.stringify(result),/guest@example.com|Existing-secret/);
  });
}

test('duplicate-account login with the wrong password stops without registering again', async () => {
  const doc=createDocument(),email=el(doc,'input',{type:'email'}),password=el(doc,'input',{type:'password'});
  const submit=button(doc,'Sign In'),form=el(doc,'form',{action:'/login'},[email,password,submit]);doc.body.appendChild(form);
  const branch=el(doc,'a',{href:'#'},['Create an account']);doc.body.appendChild(branch);
  branch.addEventListener('click',()=>assert.fail('Rejected login must not register again'));
  let clicks=0;submit.addEventListener('click',()=>{clicks++;password.setAttribute('aria-invalid','true');form.appendChild(el(doc,'p',{class:'error'},['Incorrect password']))});
  const result=await autofill.run({doc,credentials:{operation:'existing',username:'saved@example.com',password:'Wrong-secret!'},...FAST_TIMEOUTS});
  assert.equal(result.status,'unsupported');assert.equal(clicks,1);
});

test('returning-account passwords stay empty without credentials or a signup branch', async () => {
  const doc=createDocument(),password=el(doc,'input',{type:'password',name:'password'});
  doc.body.appendChild(el(doc,'form',{action:'/login'},[el(doc,'input',{name:'email',type:'email'}),password,button(doc,'Sign In')]));
  const result=await autofill.run({doc,identity:{email:'guest@example.com',password:'Made-up-secret!'},...FAST_TIMEOUTS});
  assert.equal(result.status,'unsupported');assert.equal(result.detail,'account_credentials_required');assert.equal(password.value,'');assert.equal(result.journey.actions,0);
});

test('required new-account username and password fields use the signup Persona', async () => {
  const doc=createDocument(),user=el(doc,'input',{autocomplete:'username',required:''});
  const password=el(doc,'input',{type:'password',autocomplete:'new-password',required:''});
  const submit=button(doc,'Get online'),form=el(doc,'form',{},[user,password,submit]);doc.body.appendChild(form);
  submit.addEventListener('click',()=>{assert.equal(user.value,'guest@example.com');assert.equal(password.value,'New-secret!');doc.body.removeChild(form)});
  const result=await autofill.run({doc,identity:{email:'guest@example.com',password:'New-secret!'},...FAST_TIMEOUTS});
  assert.equal(result.status,'submitted');assert.equal(result.journey.actions,1);
});

test('an explicit create operation takes registration before returning-account login', async () => {
  const doc=createDocument(),login=el(doc,'form',{action:'/login'},[el(doc,'input',{type:'email',required:''}),el(doc,'input',{type:'password'}),button(doc,'Sign In')]);
  const branch=el(doc,'a',{href:'#'},['Create an account']);doc.body.appendChild(login);doc.body.appendChild(branch);
  let created=false;branch.addEventListener('click',()=>{
    doc.body.removeChild(login);doc.body.removeChild(branch);
    const email=el(doc,'input',{type:'email',required:''}),password=el(doc,'input',{type:'password',autocomplete:'new-password',required:''}),submit=button(doc,'Create new account');
    const signup=el(doc,'form',{action:'/signup'},[email,password,submit]);doc.body.appendChild(signup);
    submit.addEventListener('click',()=>{assert.equal(email.value,'chosen@example.com');assert.equal(password.value,'Chosen-secret!');created=true;doc.body.removeChild(signup)});
  });
  const result=await autofill.run({doc,identity:{email:'persona@example.com',password:'Persona-secret!'},credentials:{operation:'create',username:'chosen@example.com',password:'Chosen-secret!'},...FAST_TIMEOUTS});
  assert.equal(result.status,'submitted');assert.equal(created,true);assert.equal(result.journey.actions,2);
});

test('a submission survives a replacement document as a verification candidate', async () => {
  const journey={actions:1,trace:[],attempts:{},pendingSubmission:true};const doc=createDocument();doc.body.textContent='Welcome';
  const result=await autofill.run({doc,journey,...FAST_TIMEOUTS});assert.equal(result.status,'submitted');assert.equal(result.journey.actions,1);
  doc.body.textContent='Check your inbox and click the email verification link';
  const boundary=await autofill.run({doc,journey,...FAST_TIMEOUTS});assert.equal(boundary.status,'unsupported');assert.equal(boundary.detail,'email_verification');
});
test("local model interpretations are identified in the diagnostic bridge", async () => {
  const messages = [];
  const previousWindow = globalThis.window;
  globalThis.window = { webkit: { messageHandlers: { diagnosticStep: {
    postMessage: message => messages.push(message),
  } } } };
  try {
    const f = localFixture();
    const result = await autofill.run({doc:f.doc,identity:{firstName:'Sarah'},...FAST_TIMEOUTS,
      reasoner:async()=>({fields:[{key:'f0',intent:'first_name'}]})});
    assert.equal(result.status,'submitted');
    assert.ok(messages.some(m=>m.fields.some(field=>field.source==='Apple on-device model' && field.intent==='first_name')));
    assert.doesNotMatch(JSON.stringify(messages),/Sarah/);
  } finally { globalThis.window = previousWindow; }
});

test("live diagnostic bridge reports interpretation without persona values", async () => {
  const messages = [];
  const previousWindow = globalThis.window;
  globalThis.window = { webkit: { messageHandlers: { diagnosticStep: {
    postMessage: message => messages.push(message),
  } } } };
  try {
    const { doc, identity } = pretContractFixture.build();
    const result = await autofill.run({ doc, identity, ...FAST_TIMEOUTS });
    assert.equal(result.status, "submitted");
    assert.ok(messages.some(m => m.phase === "form"));
    const row = messages.flatMap(m => m.fields).find(f => f.intent === "email");
    assert.equal(row.source, "JavaScript heuristic");
    assert.equal(row.category, "Persona email");
    assert.equal(row.maskedValue, "[masked]");
    assert.ok(messages.some(m => m.title === "Ticked terms checkbox"));
    assert.ok(messages.some(m => m.title === "Left marketing unchecked"));
    assert.ok(messages.some(m => m.phase === "submit" && m.status === "running"));
    assert.ok(!JSON.stringify(messages).includes(identity.email));
    assert.ok(!JSON.stringify(messages).includes(identity.phone));
  } finally {
    if (previousWindow === undefined) delete globalThis.window;
    else globalThis.window = previousWindow;
  }
});

test('marketing dropdown answers follow question polarity and ignore option order', () => {
  for (const [question, expected] of [['Send marketing offers','no'],['Do not send marketing','yes']]) {
    for (const order of [['yes','no'],['no','yes']]) {
      for (const required of [undefined,'']) {
        const doc=createDocument();
        const select=el(doc,'select',{name:'contact',required},[
          el(doc,'option',{value:''},['Select']),
          ...order.map(value=>el(doc,'option',{value},[value === 'yes' ? 'Yes' : 'No']))
        ]);
        doc.body.appendChild(el(doc,'form',{},[el(doc,'label',{},[question,select]),button(doc,'Connect')]));
        const result=autofill.fillOneStep(doc,{});
        assert.equal(select.value,expected,question);
        assert.deepEqual(result.unresolved,[]);
      }
    }
  }
});

function provideMarketingFieldsetLookup(radios) {
  // The lightweight DOM shim has no Element.closest. Supply the browser API
  // for these fieldset fixtures so they exercise the production descriptor.
  for (const radio of radios) radio.closest = selector => {
    if (!selector.includes('fieldset')) return null;
    for (let parent=radio.parentElement; parent; parent=parent.parentElement)
      if (parent.tagName === 'FIELDSET') return parent;
    return null;
  };
}

test('marketing radios use legend polarity and full option text before server values', () => {
  for (const [question,expected] of [['Receive marketing offers','no'],['Do not send marketing','yes']]) {
    for (const order of [['yes','no'],['no','yes']]) {
      const doc=createDocument();
      const radios=order.map(value=>el(doc,'input',{name:'contact',type:'radio',value,required:''}));
      doc.body.appendChild(el(doc,'form',{},[el(doc,'fieldset',{},[el(doc,'legend',{},[question]),
        ...radios.map(radio=>el(doc,'label',{},[radio.value === 'yes' ? 'Yes' : 'No',radio]))]),button(doc,'Connect')]));
      provideMarketingFieldsetLookup(radios);
      const result=autofill.fillOneStep(doc,{});
      assert.equal(radios.find(radio=>radio.checked).value,expected);
      assert.deepEqual(result.unresolved,[]);
    }
  }
  const doc=createDocument();
  const allow=el(doc,'input',{name:'contact',type:'radio',value:'no',required:''});
  const deny=el(doc,'input',{name:'contact',type:'radio',value:'yes',required:''});
  doc.body.appendChild(el(doc,'form',{},[el(doc,'fieldset',{},[el(doc,'legend',{},['Marketing communications']),
    el(doc,'label',{},['Receive marketing offers',allow]),el(doc,'label',{},['Do not send marketing',deny])]),button(doc,'Connect')]));
  provideMarketingFieldsetLookup([allow,deny]);
  assert.deepEqual(autofill.fillOneStep(doc,{}).unresolved,[]);
  assert.equal(deny.checked,true);
  assert.equal(allow.checked,false);
});

test('marketing select fails closed for unavailable and placeholder refusals even when optional', () => {
  for (const required of [undefined,'']) {
    for (const kind of ['disabled','optgroup','placeholder','empty','unfamiliar','ambiguous']) {
      const doc=createDocument();
      let refusal=el(doc,'option',{value:kind === 'empty' ? '' : 'yes',disabled:kind === 'disabled' ? '' : undefined},[kind === 'placeholder' ? 'Select Yes' : kind === 'unfamiliar' ? 'Unfamiliar answer' : 'Yes']);
      if(kind === 'optgroup')refusal=el(doc,'optgroup',{disabled:''},[refusal]);
      const select=el(doc,'select',{name:'contact',required},[refusal,el(doc,'option',{value:'no'},['No']),...(kind === 'ambiguous' ? [el(doc,'option',{value:'also_yes'},['Yes'])] : [])]);
      doc.body.appendChild(el(doc,'form',{},[el(doc,'label',{},['Do not send marketing',select]),button(doc,'Connect')]));
      assert.equal(autofill.fillOneStep(doc,{}).unresolved.length,1,kind);
    }
  }
});

test('unavailable marketing radio refusal never selects disabled or hidden choices', () => {
  for (const attrs of [{disabled:''},{style:'display:none'}]) {
    const doc=createDocument();
    const yes=el(doc,'input',{name:'contact',type:'radio',value:'yes',...attrs});
    const no=el(doc,'input',{name:'contact',type:'radio',value:'no',required:''});no.checked=true;
    doc.body.appendChild(el(doc,'form',{},[el(doc,'fieldset',{},[el(doc,'legend',{},['Do not send marketing']),
      el(doc,'label',{},['Yes',yes]),el(doc,'label',{},['No',no])]),button(doc,'Connect')]));
    provideMarketingFieldsetLookup([yes,no]);
    assert.equal(autofill.fillOneStep(doc,{}).unresolved.length,1);
    assert.equal(yes.checked,false);
    assert.equal(no.checked,false);
  }
});

test('marketing choices use displayed option label instead of hidden text', () => {
  for (const order of [['allow','deny'],['deny','allow']]) {
    const doc=createDocument();
    const select=el(doc,'select',{name:'contact',required:''},order.map(value=>
      el(doc,'option',{value,label:value === 'allow' ? 'Receive marketing' : 'No thanks'},[value === 'allow' ? 'No' : 'Yes'])));
    doc.body.appendChild(el(doc,'form',{},[el(doc,'label',{},['Receive marketing',select]),button(doc,'Connect')]));
    assert.deepEqual(autofill.fillOneStep(doc,{}).unresolved,[]);
    assert.equal(select.value,'deny');
  }
  for (const label of ['', '   ', 'Select']) {
    const doc=createDocument();
    const select=el(doc,'select',{name:'contact',required:''},[
      el(doc,'option',{value:'yes'},['Yes']),el(doc,'option',{value:'no',label},['No'])]);
    doc.body.appendChild(el(doc,'form',{},[el(doc,'label',{},['Receive marketing',select]),button(doc,'Connect')]));
    const result=autofill.fillOneStep(doc,{});
    assert.equal(result.unresolved.length,label === '' ? 0 : 1);
    if(label === '')assert.equal(select.value,'no');
  }
});
