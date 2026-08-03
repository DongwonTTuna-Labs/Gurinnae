#!/usr/bin/env python3
from __future__ import annotations
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from datetime import date
import hashlib, json, sys

Q=Decimal('0.0001')
def D(v): return Decimal(str(v))
def q(v): return str(D(v).quantize(Q, rounding=ROUND_HALF_UP))
def canonical(obj): return json.dumps(obj,ensure_ascii=False,sort_keys=True,separators=(',',':'))
def sha(obj): return hashlib.sha256(canonical(obj).encode()).hexdigest()
def blocked(code, input_obj):
    result={'outcome':'BLOCKED','blockers':[code],'metrics':{},'included_ids':[],'excluded_ids':[]}
    result['input_hash']=sha(input_obj); result['result_hash']=sha(result); return result
def finish(outcome, blockers, metrics, included, excluded, input_obj):
    result={'outcome':outcome,'blockers':blockers,'metrics':metrics,'included_ids':sorted(included),'excluded_ids':sorted(excluded)}
    result['input_hash']=sha(input_obj); result['result_hash']=sha(result); return result
def missing(obj,path):
    cur=obj
    for p in path.split('.'):
        if not isinstance(cur,dict) or p not in cur or cur[p] is None: return True
        cur=cur[p]
    return False

def eval_price(x):
    for p in ['target.id','target.unit_price','target.unit','target.category','target.vat_included','target.bundle_known','target.observed_at','comparables']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    t=x['target']
    if not t['bundle_known']: return blocked('TARGET_BUNDLE_UNKNOWN',x)
    if t['vat_included'] is None: return blocked('TARGET_VAT_UNKNOWN',x)
    seen=set(); included=[]; excluded=[]; vals=[]
    td=date.fromisoformat(t['observed_at'])
    for c in x['comparables']:
        cid=c.get('id','UNKNOWN')
        key=c.get('source_key',cid)
        ok=True
        if key in seen: ok=False
        seen.add(key)
        for field in ['unit_price','unit','category','vat_included','bundle_known','observed_at']:
            if c.get(field) is None: ok=False
        if ok and (c['unit']!=t['unit'] or c['category']!=t['category'] or c['vat_included']!=t['vat_included'] or not c['bundle_known']): ok=False
        if ok and abs((td-date.fromisoformat(c['observed_at'])).days)>365: ok=False
        if ok: included.append(cid); vals.append(D(c['unit_price']))
        else: excluded.append(cid)
    if len(vals)<8: return blocked('INSUFFICIENT_COMPARABLES',x)
    vals.sort(); n=len(vals); med=vals[n//2] if n%2 else (vals[n//2-1]+vals[n//2])/2
    ratio=D(t['unit_price'])/med
    return finish('SIGNAL' if ratio>=D(3) else 'NO_SIGNAL',[],{'target_unit_price':str(t['unit_price']),'median_unit_price':q(med),'ratio':q(ratio),'comparable_count':len(vals)},included,excluded,x)

def contract_groups(contracts):
    dedup={c['id']:c for c in contracts if c.get('id')}; return list(dedup.values())
def eval_split(x):
    for p in ['contracts','single_source_threshold','window_days']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    cs=contract_groups(x['contracts'])
    required=['agency_id','supplier_id','category','signed_at','amount','method']
    if any(any(c.get(f) is None for f in required) for c in cs): return blocked('REQUIRED_FIELD_MISSING',x)
    candidates=[c for c in cs if c['method']=='SINGLE_SOURCE' and D(c['amount'])<D(x['single_source_threshold']) and not c.get('legitimate_phase',False)]
    groups={}
    for c in candidates: groups.setdefault((c['agency_id'],c['supplier_id'],c['category']),[]).append(c)
    matched=[]
    for g in groups.values():
        g.sort(key=lambda c:c['signed_at']); span=(date.fromisoformat(g[-1]['signed_at'])-date.fromisoformat(g[0]['signed_at'])).days
        if len(g)>=3 and span<=int(x['window_days']) and sum(D(c['amount']) for c in g)>=D(x['single_source_threshold']): matched.extend(c['id'] for c in g)
    return finish('SIGNAL' if matched else 'NO_SIGNAL',[],{'matched_contract_count':len(set(matched)),'threshold':str(x['single_source_threshold'])},matched,[c['id'] for c in cs if c['id'] not in matched],x)

def eval_repeated(x):
    for p in ['contracts','window_days']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    cs=contract_groups(x['contracts'])
    req=['agency_id','supplier_id','category','signed_at','amount','method']
    if any(any(c.get(f) is None for f in req) for c in cs): return blocked('REQUIRED_FIELD_MISSING',x)
    groups={}
    for c in cs:
        if c['method']=='SINGLE_SOURCE': groups.setdefault((c['agency_id'],c['supplier_id'],c['category']),[]).append(c)
    matched=[]; total=Decimal(0)
    for g in groups.values():
        g.sort(key=lambda c:c['signed_at']); span=(date.fromisoformat(g[-1]['signed_at'])-date.fromisoformat(g[0]['signed_at'])).days
        amt=sum(D(c['amount']) for c in g); days=len({c['signed_at'] for c in g})
        if len(g)>=4 and days>=3 and span<=int(x['window_days']) and amt>=D(50000000): matched.extend(c['id'] for c in g); total=max(total,amt)
    return finish('SIGNAL' if matched else 'NO_SIGNAL',[],{'matched_contract_count':len(set(matched)),'matched_total_amount':str(total)},matched,[c['id'] for c in cs if c['id'] not in matched],x)

def eval_concentration(x):
    for p in ['contracts','minimum_total_spend']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    cs=contract_groups(x['contracts'])
    if any(c.get('supplier_id') is None or c.get('amount') is None for c in cs): return blocked('IDENTITY_AMBIGUOUS',x)
    total=sum(D(c['amount']) for c in cs)
    if total<D(x['minimum_total_spend']): return blocked('INSUFFICIENT_TOTAL_SPEND',x)
    sums={}; counts={}
    for c in cs: sums[c['supplier_id']]=sums.get(c['supplier_id'],Decimal(0))+D(c['amount']); counts[c['supplier_id']]=counts.get(c['supplier_id'],0)+1
    sid=max(sums,key=sums.get); share=sums[sid]/total
    matched=[c['id'] for c in cs if c['supplier_id']==sid]
    signal=share>=D('0.6') and counts[sid]>=3
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],{'top_supplier_id':sid,'top_supplier_share':q(share),'top_supplier_contract_count':counts[sid],'total_spend':str(total)},matched if signal else [],[c['id'] for c in cs if not signal or c['supplier_id']!=sid],x)

def eval_low_comp(x):
    for p in ['procurement.id','procurement.method','procurement.valid_bidder_count','procurement.estimated_amount','procurement.emergency']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    p=x['procurement']; competitive=p['method'] in ['OPEN_COMPETITION','LIMITED_COMPETITION']; signal=competitive and int(p['valid_bidder_count'])<=1 and D(p['estimated_amount'])>=D(50000000) and not p['emergency']
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],{'valid_bidder_count':int(p['valid_bidder_count']),'estimated_amount':str(p['estimated_amount']),'competitive':competitive,'emergency':bool(p['emergency'])},[p['id']] if signal else [],[] if signal else [p['id']],x)

def eval_amendment(x):
    for p in ['contract.id','contract.original_amount','contract.final_amount','contract.amendment_count','contract.scope_change_explained']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    c=x['contract']; orig=D(c['original_amount'])
    if orig<=0: return blocked('ORIGINAL_AMOUNT_ZERO',x)
    ratio=D(c['final_amount'])/orig; signal=orig>=D(10000000) and int(c['amendment_count'])>=2 and ratio>=D('1.5') and not c['scope_change_explained']
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],{'original_amount':str(c['original_amount']),'final_amount':str(c['final_amount']),'ratio':q(ratio),'amendment_count':int(c['amendment_count']),'scope_change_explained':bool(c['scope_change_explained'])},[c['id']] if signal else [],[] if signal else [c['id']],x)

def median(vals):
    vals=sorted(vals); n=len(vals); return vals[n//2] if n%2 else (vals[n//2-1]+vals[n//2])/2

def eval_year_end(x):
    for p in ['monthly_spend','monthly_contract_count']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    if len(x['monthly_spend'])!=12 or len(x['monthly_contract_count'])!=12: return blocked('INCOMPLETE_YEAR',x)
    spends=[D(v) for v in x['monthly_spend']]; counts=[int(v) for v in x['monthly_contract_count']]
    if sum(counts)<10: return blocked('INSUFFICIENT_CONTRACTS',x)
    annual=sum(spends); prior=median(spends[:11]); dec=spends[11]
    if annual<=0 or prior<=0: return blocked('INCOMPLETE_YEAR',x)
    share=dec/annual; ratio=dec/prior; signal=share>=D('0.25') and ratio>=D('3')
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],{'annual_spend':str(annual),'december_spend':str(dec),'december_share':q(share),'prior_month_median':q(prior),'december_to_prior_median':q(ratio),'annual_contract_count':sum(counts)},['month-12'] if signal else [],[] if signal else ['month-12'],x)

def eval_new_supplier(x):
    for p in ['supplier.id','supplier.age_days','supplier.agency_contract_count','supplier.agency_spend','supplier.total_public_spend','supplier.identity_verified']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    s=x['supplier']
    if not s['identity_verified']: return blocked('IDENTITY_AMBIGUOUS',x)
    total=D(s['total_public_spend'])
    if total<=0: return blocked('TOTAL_SPEND_ZERO',x)
    share=D(s['agency_spend'])/total; signal=int(s['age_days'])<=365 and int(s['agency_contract_count'])>=3 and D(s['agency_spend'])>=D(50000000) and share>=D('0.5')
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],{'supplier_age_days':int(s['age_days']),'agency_contract_count':int(s['agency_contract_count']),'agency_spend':str(s['agency_spend']),'total_public_spend':str(s['total_public_spend']),'agency_share':q(share)},[s['id']] if signal else [],[] if signal else [s['id']],x)

def eval_shared(x):
    for p in ['suppliers','contracts']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    suppliers=x['suppliers']; contracts=contract_groups(x['contracts'])
    if len(suppliers)<2 or len(contracts)<3: return blocked('INSUFFICIENT_CONTRACT_CONTEXT',x)
    if any(not s.get('strong_identifier_hashes') for s in suppliers): return blocked('IDENTITY_HASH_MISSING',x)
    best=None
    for i,a in enumerate(suppliers):
        for b in suppliers[i+1:]:
            shared=set(a['strong_identifier_hashes']) & set(b['strong_identifier_hashes'])
            relevant=[c for c in contracts if c.get('supplier_id') in {a['id'],b['id']}]
            agencies={c.get('agency_id') for c in relevant}; amt=sum(D(c.get('amount',0)) for c in relevant)
            if len(shared)>=2 and len(relevant)>=3 and len(agencies)==1 and amt>=D(50000000): best=(a,b,shared,relevant,amt); break
        if best: break
    if not best: return finish('NO_SIGNAL',[],{'shared_identifier_count':0,'combined_contract_count':0,'combined_amount':'0'},[],[c['id'] for c in contracts],x)
    a,b,shared,relevant,amt=best
    return finish('SIGNAL',[],{'supplier_ids':[a['id'],b['id']],'shared_identifier_count':len(shared),'combined_contract_count':len(relevant),'combined_amount':str(amt)},[c['id'] for c in relevant],[c['id'] for c in contracts if c not in relevant],x)

def eval_restrictive(x):
    for p in ['specification.id','specification.brand_mentions','specification.model_mentions','specification.equivalent_allowed','specification.valid_bidder_count','specification.justification_present']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    s=x['specification']; mentions=int(s['brand_mentions'])+int(s['model_mentions']); signal=mentions>=1 and not s['equivalent_allowed'] and int(s['valid_bidder_count'])<=1 and not s['justification_present']
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],{'brand_mentions':int(s['brand_mentions']),'model_mentions':int(s['model_mentions']),'equivalent_allowed':bool(s['equivalent_allowed']),'valid_bidder_count':int(s['valid_bidder_count']),'justification_present':bool(s['justification_present'])},[s['id']] if signal else [],[] if signal else [s['id']],x)

def lower_sha256(value):
    return isinstance(value,str) and len(value)==64 and all(c in '0123456789abcdef' for c in value)

def eval_officer_overlap(x):
    required=['policy.minimum_distinct_suppliers','source_coverage.dart_officer_assignments_complete','source_coverage.award_records_complete','source_coverage.relationship_periods_complete','source_coverage.relationships_verified','source_coverage.public_use_approved','source_coverage.independent_human_verification_complete','awards','officer_assignments']
    if any(missing(x,p) for p in required): return blocked('REQUIRED_FIELD_MISSING',x)
    minimum=x['policy']['minimum_distinct_suppliers']
    if not isinstance(minimum,int) or isinstance(minimum,bool) or minimum<2: return blocked('INVALID_POLICY_THRESHOLD',x)
    coverage=x['source_coverage']
    if any(coverage[p] is False for p in ['dart_officer_assignments_complete','award_records_complete','relationship_periods_complete']): return blocked('SOURCE_COVERAGE_INCOMPLETE',x)
    if any(coverage[p] is False for p in ['relationships_verified','public_use_approved','independent_human_verification_complete']): return blocked('RELATIONSHIP_GRAPH_NOT_APPROVED',x)
    awards=x['awards']; assignments=x['officer_assignments']
    if not awards or not assignments: return blocked('INSUFFICIENT_CONTEXT',x)
    seen=set(); parsed_awards=[]
    for award in awards:
        if any(award.get(k) is None for k in ['id','agency_id','supplier_id','awarded_on']): return blocked('REQUIRED_FIELD_MISSING',x)
        if award['id'] in seen: return blocked('DUPLICATE_RECORD_ID',x)
        seen.add(award['id'])
        try: awarded_on=date.fromisoformat(award['awarded_on'])
        except (TypeError,ValueError): return blocked('DATE_INVALID',x)
        parsed_awards.append((award['id'],award['agency_id'],award['supplier_id'],awarded_on))
    seen=set(); parsed_assignments=[]
    for role in assignments:
        if any(role.get(k) is None for k in ['id','person_identifier_digest','supplier_id','valid_from','valid_to']): return blocked('REQUIRED_FIELD_MISSING',x)
        if role['id'] in seen: return blocked('DUPLICATE_RECORD_ID',x)
        seen.add(role['id'])
        if not lower_sha256(role['person_identifier_digest']): return blocked('PERSON_IDENTITY_DIGEST_INVALID',x)
        try: valid_from=date.fromisoformat(role['valid_from']); valid_to=date.fromisoformat(role['valid_to'])
        except (TypeError,ValueError): return blocked('DATE_INVALID',x)
        if valid_from>valid_to: return blocked('VALIDITY_INTERVAL_INVALID',x)
        parsed_assignments.append((role['person_identifier_digest'],role['supplier_id'],valid_from,valid_to))
    candidates={}
    for award_id,agency_id,supplier_id,awarded_on in parsed_awards:
        for person_digest,role_supplier_id,valid_from,valid_to in parsed_assignments:
            if supplier_id==role_supplier_id and valid_from<=awarded_on<=valid_to:
                key=(agency_id,person_digest); current=candidates.setdefault(key,{'suppliers':set(),'awards':set()})
                current['suppliers'].add(supplier_id); current['awards'].add(award_id)
    best=None
    for key in sorted(candidates):
        candidate=candidates[key]
        if best is None or len(candidate['suppliers'])>len(best[1]['suppliers']): best=(key,candidate)
    signal=best is not None and len(best[1]['suppliers'])>=minimum
    included=sorted(best[1]['awards']) if signal else []
    metrics={'minimum_distinct_suppliers':minimum,'matched_distinct_supplier_count':len(best[1]['suppliers']) if best else 0,'matched_award_count':len(best[1]['awards']) if best else 0}
    if signal:
        metrics['agency_id']=best[0][0]; metrics['person_identifier_digest']=best[0][1]
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],metrics,included,[a['id'] for a in awards if a['id'] not in set(included)],x)

def eval_ownership_linked(x):
    policy=x.get('policy')
    if not isinstance(policy,dict): return blocked('POLICY_MISSING',x)
    minimum=policy.get('minimum_linked_participants'); hops=policy.get('maximum_relationship_hops')
    if not isinstance(minimum,int) or isinstance(minimum,bool) or not isinstance(hops,int) or isinstance(hops,bool): return blocked('POLICY_MISSING',x)
    if minimum!=2 or hops not in (1,2): return blocked('POLICY_INVALID',x)
    procurement=x.get('procurement')
    if not isinstance(procurement,dict): return blocked('PARTICIPANT_RECORD_INCOMPLETE',x)
    source=procurement.get('structured_participant_source')
    if not isinstance(source,dict) or not source.get('authority') or source.get('status')!='STRUCTURED_COMPLETE': return blocked('STRUCTURED_BIDDER_SOURCE_UNAVAILABLE',x)
    if source.get('coverage_complete') is not True: return blocked('STRUCTURED_BIDDER_COVERAGE_INCOMPLETE',x)
    if not isinstance(procurement.get('id'),str): return blocked('PARTICIPANT_RECORD_INCOMPLETE',x)
    try: opened=date.fromisoformat(procurement['bid_opened_at'])
    except (KeyError,TypeError,ValueError): return blocked('RELATIONSHIP_PERIOD_INCOMPLETE',x)
    participants=procurement.get('participants')
    if not isinstance(participants,list): return blocked('PARTICIPANT_RECORD_INCOMPLETE',x)
    valid=set()
    for row in participants:
        if not isinstance(row,dict) or not all(isinstance(row.get(k),str) for k in ['supplier_id','participation_status','identity_status']): return blocked('PARTICIPANT_RECORD_INCOMPLETE',x)
        status=row['participation_status']
        if status=='VALID':
            if row['identity_status']!='VERIFIED': return blocked('PARTICIPANT_IDENTITY_INCOMPLETE',x)
            valid.add(row['supplier_id'])
        elif status not in {'WITHDRAWN','DISQUALIFIED','INVALID'}: return blocked('PARTICIPANT_RECORD_INCOMPLETE',x)
    if x.get('relationship_coverage_complete') is not True: return blocked('RELATIONSHIP_COVERAGE_INCOMPLETE',x)
    relationships=x.get('relationships')
    if not isinstance(relationships,list): return blocked('RELATIONSHIP_COVERAGE_INCOMPLETE',x)
    all_ids=set(); edges=[]
    ignored={'BENEFICIAL_OWNERSHIP','SHARED_BANK','SHARED_PHONE','SHARED_ADDRESS','MANAGEMENT_ROLE','BID_PARTICIPATION','SANCTION','FORMER_OFFICIAL_ROLE'}
    for row in relationships:
        if not isinstance(row,dict) or not isinstance(row.get('id'),str): return blocked('RELATIONSHIP_PATH_INCOMPLETE',x)
        if row['id'] in all_ids: return blocked('RELATIONSHIP_PATH_INCOMPLETE',x)
        all_ids.add(row['id']); kind=row.get('kind')
        if kind in ignored: continue
        if kind not in {'OWNERSHIP','CONTROL'}: return blocked('RELATIONSHIP_KIND_UNKNOWN',x)
        required=['source_supplier_id','target_supplier_id','verification_status','public_use_status']
        if any(not isinstance(row.get(k),str) for k in required): return blocked('RELATIONSHIP_PATH_INCOMPLETE',x)
        if row.get('source_identity_status')!='VERIFIED' or row.get('target_identity_status')!='VERIFIED': return blocked('RELATIONSHIP_IDENTITY_INCOMPLETE',x)
        if row.get('period_coverage_complete') is not True: return blocked('RELATIONSHIP_PERIOD_INCOMPLETE',x)
        try: start=date.fromisoformat(row['valid_from']); end=date.fromisoformat(row['valid_to'])
        except (KeyError,TypeError,ValueError): return blocked('RELATIONSHIP_PERIOD_INCOMPLETE',x)
        if start>end: return blocked('RELATIONSHIP_PERIOD_INCOMPLETE',x)
        if row['verification_status']!='VERIFIED' or row['public_use_status']!='APPROVED': continue
        if row['source_supplier_id']!=row['target_supplier_id'] and start<=opened<=end: edges.append((row['id'],row['source_supplier_id'],row['target_supplier_id']))
    edges.sort(); matched=None
    def connects(edge,a,b): return (edge[1]==a and edge[2]==b) or (edge[1]==b and edge[2]==a)
    for i,a in enumerate(sorted(valid)):
        for b in sorted(valid)[i+1:]:
            paths=[[e[0]] for e in edges if connects(e,a,b)]
            if hops>=2:
                for e1 in edges:
                    middle=e1[2] if e1[1]==a else e1[1] if e1[2]==a else None
                    if middle is None or middle==b: continue
                    for e2 in edges:
                        if e1[0]!=e2[0] and connects(e2,middle,b): paths.append([e1[0],e2[0]])
            if paths:
                paths.sort(); path=min(paths,key=len); matched=(a,b,path); break
        if matched: break
    metrics={'procurement_id':procurement['id'],'valid_participant_count':len(valid),'maximum_relationship_hops':hops,'linked_participant_ids':[matched[0],matched[1]] if matched else [],'path_hops':len(matched[2]) if matched else 0,'relationship_ids':matched[2] if matched else []}
    universe=set(valid)|all_ids|{procurement['id']}; included=[procurement['id'],matched[0],matched[1],*matched[2]] if matched else []
    return finish('SIGNAL' if matched else 'NO_SIGNAL',[],metrics,included,universe-set(included),x)

def eval_bid_rotation(x):
    policy=x.get('policy')
    if not isinstance(policy,dict): return blocked('REQUIRED_FIELD_MISSING',x)
    required=['minimum_notice_count','window_days','minimum_bidders_per_notice','minimum_distinct_winners','cluster_metric','cluster_tolerance_bps','currency','tie_handling']
    if any(policy.get(field) is None for field in required): return blocked('REQUIRED_FIELD_MISSING',x)
    try:
        notice_min=policy['minimum_notice_count']; window=policy['window_days']; bidder_min=policy['minimum_bidders_per_notice']; winner_min=policy['minimum_distinct_winners']; tolerance=D(policy['cluster_tolerance_bps']); currency=policy['currency']
    except (TypeError,ValueError): return blocked('INVALID_POLICY',x)
    integers=[notice_min,window,bidder_min,winner_min]
    if any(not isinstance(v,int) or isinstance(v,bool) for v in integers) or notice_min<3 or window<0 or bidder_min<3 or winner_min<2 or winner_min>bidder_min or tolerance<0 or policy.get('cluster_metric')!='LOSING_BID_RANGE_BPS' or policy.get('tie_handling')!='BLOCK' or not isinstance(currency,str) or not currency: return blocked('INVALID_POLICY',x)
    source_status=x.get('participant_source',{}).get('status')
    if source_status is None: return blocked('REQUIRED_FIELD_MISSING',x)
    if source_status!='STRUCTURED_COMPLETE': return blocked('STRUCTURED_PARTICIPANT_SOURCE_UNAVAILABLE',x)
    if x.get('observation_period_complete') is not True: return blocked('PERIOD_COVERAGE_INCOMPLETE',x)
    values=x.get('notices')
    if not isinstance(values,list): return blocked('REQUIRED_FIELD_MISSING',x)
    notices=[]; seen=set()
    for row in values:
        if not isinstance(row,dict): return blocked('REQUIRED_FIELD_MISSING',x)
        if row.get('participant_set_complete') is not True: return blocked('PARTICIPANT_SET_INCOMPLETE',x)
        if row.get('winner_complete') is not True: return blocked('WINNER_INCOMPLETE',x)
        if row.get('price_coverage_complete') is not True: return blocked('PRICE_COVERAGE_INCOMPLETE',x)
        if not all(isinstance(row.get(k),str) and row[k] for k in ['id','agency_id','noticed_at']): return blocked('REQUIRED_FIELD_MISSING',x)
        if row['id'] in seen: return blocked('DUPLICATE_NOTICE_ID',x)
        seen.add(row['id'])
        try: noticed=date.fromisoformat(row['noticed_at'])
        except ValueError: return blocked('PERIOD_COVERAGE_INCOMPLETE',x)
        winner=row.get('winner_supplier_id')
        if not isinstance(winner,str) or not winner: return blocked('WINNER_INCOMPLETE',x)
        participants=row.get('participants')
        if not isinstance(participants,list): return blocked('PARTICIPANT_SET_INCOMPLETE',x)
        bids={}
        for participant in participants:
            if not isinstance(participant,dict) or not isinstance(participant.get('supplier_id'),str) or not participant['supplier_id']: return blocked('REQUIRED_FIELD_MISSING',x)
            if participant.get('currency')!=currency: return blocked('CURRENCY_MISMATCH',x)
            try: amount=D(participant['bid_amount'])
            except (KeyError,TypeError,ValueError): return blocked('PRICE_COVERAGE_INCOMPLETE',x)
            if amount<=0: return blocked('PRICE_COVERAGE_INCOMPLETE',x)
            if participant['supplier_id'] in bids: return blocked('PARTICIPANT_IDENTITY_AMBIGUOUS',x)
            bids[participant['supplier_id']]=amount
        if winner not in bids: return blocked('WINNER_INCOMPLETE',x)
        if not bids: return blocked('PARTICIPANT_SET_INCOMPLETE',x)
        low=min(bids.values())
        if sum(amount==low for amount in bids.values())>1: return blocked('BID_TIE',x)
        if bids[winner]!=low: return blocked('WINNER_PRICE_INCONSISTENT',x)
        losing=[amount for supplier,amount in bids.items() if supplier!=winner]
        if not losing: return blocked('PARTICIPANT_SET_INCOMPLETE',x)
        losing_range=(max(losing)-min(losing))/min(losing)*D(10000)
        notices.append({'id':row['id'],'agency':row['agency_id'],'date':noticed,'winner':winner,'bids':bids,'range':losing_range})
    notices.sort(key=lambda n:(n['date'],n['id'])); ids=[n['id'] for n in notices]
    same_agency=not notices or all(n['agency']==notices[0]['agency'] for n in notices)
    same_set=not notices or all(set(n['bids'])==set(notices[0]['bids']) for n in notices)
    maximum=max((n['range'] for n in notices),default=D(0)); distinct=len({n['winner'] for n in notices}); minimum_bidders=min((len(n['bids']) for n in notices),default=0); span=(notices[-1]['date']-notices[0]['date']).days if notices else 0; rotates=all(a['winner']!=b['winner'] for a,b in zip(notices,notices[1:])); clustered=maximum<=tolerance
    signal=len(notices)>=notice_min and minimum_bidders>=bidder_min and distinct>=winner_min and same_agency and same_set and rotates and span<=window and clustered
    metrics={'notice_count':len(notices),'minimum_bidder_count':minimum_bidders,'distinct_winner_count':distinct,'window_span_days':span,'maximum_losing_bid_range_bps':q(maximum),'same_agency':same_agency,'same_participant_set':same_set,'winners_rotate':rotates,'losing_prices_clustered':clustered,'cluster_metric':'LOSING_BID_RANGE_BPS','currency':currency}
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],metrics,ids if signal else [],[] if signal else ids,x)

def eval_revolving_door(x):
    policy=x.get('policy')
    if policy is None: return blocked('REQUIRED_FIELD_MISSING',x)
    if not isinstance(policy,dict): return blocked('INVALID_FIELD_SHAPE',x)
    required=['cooling_period_days','procurement_method_allowlist','cooling_boundary']
    if any(k not in policy for k in required): return blocked('REQUIRED_FIELD_MISSING',x)
    days=policy['cooling_period_days']; methods=policy['procurement_method_allowlist']; boundary=policy['cooling_boundary']
    if not isinstance(days,int) or isinstance(days,bool) or days<=0 or not isinstance(methods,list) or not methods or boundary!='DEPARTURE_EXCLUSIVE_COOLING_END_INCLUSIVE': return blocked('POLICY_CONFIGURATION_INVALID',x)
    method_set=set()
    for method in methods:
        if not isinstance(method,str) or not method or len(method)>64 or any(not(c.isupper() or c.isdigit() or c=='_') for c in method) or method in method_set: return blocked('POLICY_CONFIGURATION_INVALID',x)
        method_set.add(method)
    coverage=x.get('source_coverage')
    if coverage is None: return blocked('REQUIRED_FIELD_MISSING',x)
    if not isinstance(coverage,dict): return blocked('INVALID_FIELD_SHAPE',x)
    if 'official_reemployment_source_available' not in coverage or 'coverage_complete' not in coverage: return blocked('REQUIRED_FIELD_MISSING',x)
    if coverage['official_reemployment_source_available'] is not True: return blocked('OFFICIAL_REEMPLOYMENT_SOURCE_UNAVAILABLE',x)
    if coverage['coverage_complete'] is not True: return blocked('OFFICIAL_REEMPLOYMENT_COVERAGE_INCOMPLETE',x)
    for key in ['former_official_roles','supplier_officer_roles','contracts']:
        if key not in x: return blocked('REQUIRED_FIELD_MISSING',x)
        if not isinstance(x[key],list): return blocked('INVALID_FIELD_SHAPE',x)
    def relationship(row,kind,subject,obj):
        if not isinstance(row,dict): return 'INVALID_FIELD_SHAPE'
        required=['relationship_kind','subject_kind','object_kind','validity_coverage_status','verification_status','public_use_status','independent_human_verification','evidence_id','source_locator']
        if any(k not in row for k in required): return 'REQUIRED_FIELD_MISSING'
        if row['relationship_kind']!=kind or row['subject_kind']!=subject or row['object_kind']!=obj: return 'RELATIONSHIP_SHAPE_INVALID'
        if row['validity_coverage_status']!='COMPLETE': return 'TEMPORAL_COVERAGE_INCOMPLETE'
        if row['verification_status']!='VERIFIED' or row['public_use_status']!='APPROVED' or row['independent_human_verification'] is not True: return 'RELATIONSHIP_REVIEW_INCOMPLETE'
        if not isinstance(row['evidence_id'],str) or not row['evidence_id'] or not isinstance(row['source_locator'],str) or not row['source_locator']: return 'INVALID_FIELD_SHAPE'
        return None
    former=[]
    for row in x['former_official_roles']:
        code=relationship(row,'FORMER_OFFICIAL_ROLE','PERSON','AGENCY')
        if code: return blocked(code,x)
        if row.get('source_kind') not in {'PUBLIC_OFFICIAL_ETHICS_NOTICE','OFFICIAL_GAZETTE'}: return blocked('OFFICIAL_REEMPLOYMENT_SOURCE_UNAVAILABLE',x)
        if not lower_sha256(row.get('person_identifier_digest')): return blocked('PERSON_IDENTITY_AMBIGUOUS',x)
        if any(not isinstance(row.get(k),str) or not row[k] for k in ['relationship_id','agency_id']): return blocked('INVALID_FIELD_SHAPE',x)
        if 'departed_on' not in row: return blocked('REQUIRED_FIELD_MISSING',x)
        try: departed=date.fromisoformat(row['departed_on'])
        except (TypeError,ValueError): return blocked('TEMPORAL_COVERAGE_INCOMPLETE',x)
        former.append((row['relationship_id'],row['person_identifier_digest'],row['agency_id'],departed))
    officers=[]
    for row in x['supplier_officer_roles']:
        code=relationship(row,'MANAGEMENT_ROLE','PERSON','SUPPLIER')
        if code: return blocked(code,x)
        if row.get('source_kind')!='DART_EXECUTIVE_STATUS': return blocked('OFFICER_SOURCE_NOT_AUTHORITATIVE',x)
        if not lower_sha256(row.get('person_identifier_digest')): return blocked('PERSON_IDENTITY_AMBIGUOUS',x)
        if any(not isinstance(row.get(k),str) or not row[k] for k in ['relationship_id','supplier_id']): return blocked('INVALID_FIELD_SHAPE',x)
        if 'valid_from' not in row or 'valid_to' not in row: return blocked('REQUIRED_FIELD_MISSING',x)
        try:
            start=date.fromisoformat(row['valid_from']); end=date.fromisoformat(row['valid_to']) if row['valid_to'] is not None else None
        except (TypeError,ValueError): return blocked('TEMPORAL_COVERAGE_INCOMPLETE',x)
        officers.append((row['relationship_id'],row['person_identifier_digest'],row['supplier_id'],start,end))
    contracts=[]; seen=set()
    for row in x['contracts']:
        if not isinstance(row,dict): return blocked('INVALID_FIELD_SHAPE',x)
        required=['id','agency_id','supplier_id','signed_on','procurement_method']
        if any(k not in row for k in required): return blocked('REQUIRED_FIELD_MISSING',x)
        if any(not isinstance(row[k],str) or not row[k] for k in required): return blocked('INVALID_FIELD_SHAPE',x)
        if row['id'] in seen: return blocked('DUPLICATE_CONTRACT_ID',x)
        seen.add(row['id'])
        try: signed=date.fromisoformat(row['signed_on'])
        except ValueError: return blocked('TEMPORAL_COVERAGE_INCOMPLETE',x)
        contracts.append((row['id'],row['agency_id'],row['supplier_id'],signed,row['procurement_method']))
    matched_contracts=set(); matched_people=set(); former_ids=set(); officer_ids=set()
    for contract_id,agency_id,supplier_id,signed,method in contracts:
        if method not in method_set: continue
        for officer_id,person,supplier,start,end in officers:
            if supplier!=supplier_id or signed<start or (end is not None and signed>end): continue
            for former_id,former_person,former_agency,departed in former:
                elapsed=(signed-departed).days
                if person==former_person and agency_id==former_agency and 0<elapsed<=days:
                    matched_contracts.add(contract_id); matched_people.add(person); former_ids.add(former_id); officer_ids.add(officer_id)
    signal=bool(matched_contracts)
    metrics={'cooling_period_days':days,'cooling_boundary':'DEPARTURE_EXCLUSIVE_COOLING_END_INCLUSIVE','procurement_method_allowlist':sorted(method_set),'matched_contract_count':len(matched_contracts),'matched_person_digests':sorted(matched_people),'former_role_ids':sorted(former_ids),'officer_role_ids':sorted(officer_ids)}
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],metrics,matched_contracts,[c[0] for c in contracts if c[0] not in matched_contracts],x)

def eval_sanctioned_successor(x):
    if missing(x,'policy'): return blocked('RULE_POLICY_INACTIVE',x)
    policy=x['policy']; policy_fields=['maximum_new_entity_age_days','post_sanction_award_window_days','sanction_effective_date_semantics','link_match_mode']
    if not isinstance(policy,dict) or any(policy.get(k) is None for k in policy_fields): return blocked('RULE_POLICY_INVALID',x)
    maximum_age=policy['maximum_new_entity_age_days']; post_window=policy['post_sanction_award_window_days']; anchor_mode=policy['sanction_effective_date_semantics']; link_mode=policy['link_match_mode']
    if not isinstance(maximum_age,int) or isinstance(maximum_age,bool) or not isinstance(post_window,int) or isinstance(post_window,bool) or maximum_age<0 or post_window<0 or anchor_mode not in {'START_DATE_INCLUSIVE','END_DATE_INCLUSIVE'} or link_mode not in {'STRONG_IDENTIFIER_OR_APPROVED_OFFICER','STRONG_IDENTIFIER_ONLY','APPROVED_OFFICER_ONLY'}: return blocked('RULE_POLICY_INVALID',x)
    required=['sanction_source_status','sanctions','suppliers','awards','strong_identifier_facts','supplier_officer_roles','strong_identifier_coverage_complete','officer_role_coverage_complete']
    if any(missing(x,k) for k in required): return blocked('REQUIRED_FIELD_MISSING',x)
    if x['sanction_source_status']!='READY': return blocked('SANCTION_SOURCE_NOT_READY',x)
    sanctions=x['sanctions']; suppliers=x['suppliers']; awards=x['awards']
    if not isinstance(sanctions,list) or not isinstance(suppliers,list) or not isinstance(awards,list): raise TypeError('invalid sanctioned successor collection')
    if not sanctions or len(suppliers)<2 or not awards: return blocked('INSUFFICIENT_CONTEXT',x)
    for row in sanctions:
        fields=['id','supplier_id','effective_from']+(['effective_to'] if anchor_mode=='END_DATE_INCLUSIVE' else [])
        if any(not isinstance(row,dict) or row.get(k) is None for k in fields): return blocked('REQUIRED_FIELD_MISSING',x)
    for row in suppliers:
        if not isinstance(row,dict) or any(row.get(k) is None for k in ['id','incorporated_at']): return blocked('REQUIRED_FIELD_MISSING',x)
    for row in awards:
        if not isinstance(row,dict) or any(row.get(k) is None for k in ['id','supplier_id','awarded_at']): return blocked('REQUIRED_FIELD_MISSING',x)
    supplier_by_id={}
    for supplier in suppliers:
        supplier_id=supplier['id']
        if supplier_id in supplier_by_id: return blocked('ENTITY_BINDING_MISMATCH',x)
        supplier_by_id[supplier_id]=supplier
    if any(row['supplier_id'] not in supplier_by_id for row in [*sanctions,*awards]): return blocked('ENTITY_BINDING_MISMATCH',x)
    try:
        for sanction in sanctions:
            start=date.fromisoformat(sanction['effective_from'])
            if sanction.get('effective_to') is not None and date.fromisoformat(sanction['effective_to'])<start: return blocked('TEMPORAL_COVERAGE_INCOMPLETE',x)
        for supplier in suppliers: date.fromisoformat(supplier['incorporated_at'])
    except (TypeError,ValueError): raise
    strong_schemes={'KOREAN_BUSINESS_NUMBER','OPEN_DART_CORP_CODE','KONEPS_PARTY_KEY'}; official_sources={'DART_EXECUTIVE_STATUS','ALIO_EXECUTIVE_STATUS','OFFICIAL_GAZETTE','PUBLIC_OFFICIAL_ETHICS_NOTICE'}
    def strong_set(supplier_id):
        result=set(); incomplete=False
        for fact in x['strong_identifier_facts']:
            fields=[fact.get(k) for k in ['supplier_id','scheme','value_hash','verification_status','proof_state']] if isinstance(fact,dict) else [None]*5
            if any(not isinstance(value,str) for value in fields): incomplete=True; continue
            fact_supplier,scheme,value_hash,verification,proof=fields
            if fact_supplier!=supplier_id: continue
            if scheme in strong_schemes and verification=='VERIFIED' and proof=='PROVEN_V1':
                if lower_sha256(value_hash): result.add(f'{scheme}:{value_hash}')
                else: incomplete=True
        return result,incomplete
    def approved_role(role):
        return role['relationship_kind']=='MANAGEMENT_ROLE' and role['subject_kind']=='PERSON' and role['object_kind']=='SUPPLIER' and role['verification_status']=='VERIFIED' and role['public_use_status']=='APPROVED' and role['independent_human_verification'] is True and lower_sha256(role['person_identifier_digest']) and role['source_kind'] in official_sources and all(isinstance(role[k],str) and bool(role[k].strip()) for k in ['relationship_id','evidence_id','source_locator'])
    def officer_set(supplier_id,at):
        result=set(); incomplete=False
        for role in x['supplier_officer_roles']:
            if not isinstance(role,dict) or not isinstance(role.get('supplier_id'),str): incomplete=True; continue
            if role['supplier_id']!=supplier_id: continue
            try: approved=approved_role(role)
            except (KeyError,TypeError): incomplete=True; continue
            if not approved: continue
            if role['validity_coverage_status']!='COMPLETE' or not isinstance(role.get('valid_from'),str): incomplete=True; continue
            try: start=date.fromisoformat(role['valid_from'])
            except ValueError: incomplete=True; continue
            if 'valid_to' not in role: incomplete=True; continue
            try: end=date.fromisoformat(role['valid_to']) if role['valid_to'] is not None else None
            except (TypeError,ValueError): incomplete=True; continue
            if end is not None and end<start: incomplete=True; continue
            if start<=at and (end is None or at<=end): result.add(role['person_identifier_digest'])
        return result,incomplete
    included=set(); matched_sanctions=set(); matched_awards=set(); pairs=set(); strong_matches=set(); officer_matches=set(); candidate_count=0; incomplete_link=False
    for sanction in sanctions:
        sanctioned_id=sanction['supplier_id']; anchor=date.fromisoformat(sanction['effective_from'] if anchor_mode=='START_DATE_INCLUSIVE' else sanction['effective_to'])
        for award in awards:
            successor_id=award['supplier_id']
            if successor_id==sanctioned_id: continue
            candidate_count+=1; award_date=date.fromisoformat(award['awarded_at']); incorporated=date.fromisoformat(supplier_by_id[successor_id]['incorporated_at']); age=(award_date-incorporated).days; after=(award_date-anchor).days
            if age<0: return blocked('TEMPORAL_COVERAGE_INCOMPLETE',x)
            if age>maximum_age or after<0 or after>post_window: continue
            strong=set(); officers=set(); pair_incomplete=False
            if link_mode!='APPROVED_OFFICER_ONLY':
                first_strong,first_incomplete=strong_set(sanctioned_id); second_strong,second_incomplete=strong_set(successor_id); strong=first_strong&second_strong; pair_incomplete |= (first_incomplete or second_incomplete or x['strong_identifier_coverage_complete'] is not True) and not strong
            if link_mode!='STRONG_IDENTIFIER_ONLY':
                first,first_incomplete=officer_set(sanctioned_id,anchor); second,second_incomplete=officer_set(successor_id,award_date); officers=first&second; pair_incomplete |= (first_incomplete or second_incomplete or x['officer_role_coverage_complete'] is not True) and not officers
            if not strong and not officers:
                incomplete_link |= pair_incomplete; continue
            sanction_id=sanction['id']; award_id=award['id']; pairs.add(f'{sanction_id}:{award_id}'); matched_sanctions.add(sanction_id); matched_awards.add(award_id); included.update([sanction_id,award_id,sanctioned_id,successor_id]); strong_matches.update(strong); officer_matches.update(officers)
    if not pairs and incomplete_link: return blocked('LINK_EVIDENCE_INCOMPLETE',x)
    evidence_ids={row['id'] for row in [*sanctions,*awards]}; included_evidence=matched_sanctions|matched_awards
    metrics={'candidate_context_count':candidate_count,'matched_context_count':len(pairs),'shared_strong_identifier_count':len(strong_matches),'shared_approved_officer_count':len(officer_matches),'maximum_new_entity_age_days':maximum_age,'post_sanction_award_window_days':post_window,'sanction_effective_date_semantics':anchor_mode,'link_match_mode':link_mode}
    return finish('SIGNAL' if pairs else 'NO_SIGNAL',[],metrics,included,evidence_ids-included_evidence,x)

EVALUATORS={'PRICE_OUTLIER':eval_price,'CONTRACT_SPLITTING_PATTERN':eval_split,'REPEATED_SINGLE_SOURCE':eval_repeated,'SUPPLIER_CONCENTRATION':eval_concentration,'LOW_BID_COMPETITION':eval_low_comp,'CONTRACT_AMENDMENT_ESCALATION':eval_amendment,'YEAR_END_SPENDING_SPIKE':eval_year_end,'NEW_SUPPLIER_DEPENDENCE':eval_new_supplier,'SHARED_SUPPLIER_IDENTITY':eval_shared,'RESTRICTIVE_SPECIFICATION':eval_restrictive,'OFFICER_OVERLAP_AWARD':eval_officer_overlap,'OWNERSHIP_LINKED_COMPETITORS':eval_ownership_linked,'BID_ROTATION':eval_bid_rotation,'REVOLVING_DOOR_CONTRACT':eval_revolving_door,'SANCTIONED_SUCCESSOR':eval_sanctioned_successor}
def evaluate(rule_id,input_obj): return EVALUATORS[rule_id](input_obj)
def main():
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('rule_id',nargs='?')
    parser.add_argument('input_file',nargs='?',type=Path)
    parser.add_argument('--json-output',type=Path)
    args=parser.parse_args()
    if bool(args.rule_id) != bool(args.input_file):
        parser.error('rule_id and input_file must be supplied together')
    if args.rule_id:
        result=evaluate(args.rule_id,json.loads(args.input_file.read_text()))
        payload=json.dumps(result,ensure_ascii=False,sort_keys=True)+'\n'
        if args.json_output:
            args.json_output.parent.mkdir(parents=True,exist_ok=True);args.json_output.write_text(payload)
        print(payload,end='');return 0
    root=Path(__file__).resolve().parent/'evals'; total=0; errors=[]
    for path in sorted(root.glob('*.jsonl')):
        for line_no,line in enumerate(path.read_text().splitlines(),1):
            if not line.strip(): continue
            case=json.loads(line); actual=evaluate(case['rule_id'],case['input'])
            if actual!=case['expected']: errors.append({'file':path.name,'line':line_no,'id':case['id'],'expected':case['expected'],'actual':actual})
            total+=1
    result={'total':total,'errors':errors,'result':'PASS' if not errors else 'FAIL'}
    payload=json.dumps(result,ensure_ascii=False,indent=2)+'\n'
    if args.json_output:
        args.json_output.parent.mkdir(parents=True,exist_ok=True);args.json_output.write_text(payload)
    print(payload,end='');return 0 if not errors else 1
if __name__=='__main__': raise SystemExit(main())
