from decimal import Decimal as D
H=lambda s:s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
M=lambda x:('&minus;$' if x<0 else '$')+f"{abs(x):,.2f}"

# (medication, Redwing line(s) at 9/30, Redwing $ at 9/30, adjustment, who, count $, count detail)
L=[
 ("Excede","Excede 100 ML + Excede 250 ML",D("7730.11"),D("-2077.36"),"done",
  D("5652.75"),"24 x 100 mL + 1 x 250 mL"),
 ("Multi Min","Multi Min",D("919.03"),D("306.34"),"jayci",D("1225.37"),"4 x 500 mL"),
 ("One Grass","One Grass",D("1804.00"),D("-1804.00"),"jayci",D("0"),"none, expired"),
 ("Synovex S","Synovex S",D("165.00"),D("-165.00"),"jayci",D("0"),"none, expired"),
 ("Synovex C 100 Ds Prestige","Synovex C",D("121.00"),D("-121.00"),"jayci",D("0"),"none, expired"),
 ("Macrosyn(Draxxin)","Macrosyn 250 ML",D("373.15"),D("-373.15"),"acct",D("0"),"none"),
 ("Enroflox(Baytril)","Enroflox 500 ML",D("3854.87"),D("0"),"",D("3854.87"),"21 x 500 mL"),
 ("Resflor","Resflor 250 ML + Resflor 500 ML",D("4153.81"),D("0"),"",D("4153.81"),"10 x 500 mL"),
 ("Cydectin","Cydectin",D("1511.96"),D("0"),"",D("1511.96"),"2 x 5 L"),
 ("Dectomax","Dectomax",D("609.50"),D("0"),"",D("609.50"),"5 x 500 mL"),
 ("Draxxin KP","Draxxin KP",D("441.00"),D("0"),"",D("441.00"),"1 x 250 mL"),
 ("Estrumate","Estrumate",D("105.00"),D("0"),"",D("105.00"),"1 x 100 mL"),
 ("Biomycin","Biomycin",D("69.44"),D("0"),"",D("69.44"),"1 x 500 mL"),
 ("Thiamine","Thiamine",D("38.38"),D("0"),"",D("38.38"),"2 x 100 mL"),
 ("Protivity","Mycroplasm 50 Dose + Mycroplasma 10 Dose",D("0"),D("0"),"open",None,
  "8 x 10-dose boxes on the shelf"),
 ("Brute","Brute",D("0"),D("0"),"",D("0"),"none"),
 ("Draxxin","Draxxin 250 ML",D("0"),D("0"),"",D("0"),"none"),
 ("Ultrachoice 8","Ultrachoice",D("0"),D("0"),"",D("0"),"none"),
 ("Vitamin K","Vitamin K",D("0"),D("0"),"",D("0"),"none"),
 ("Synovex Primer","not carried",D("0"),D("0"),"",D("0"),"none"),
 ("Ivomec Long Range Wormer","not carried",D("0"),D("0"),"recv",D("0"),
  "2 bottles here, going back to the vendor"),
 ("(not in the catalog)","Fly Spray, Valbazen, Vira Shield 50 Dose",D("0"),D("0"),"",D("0"),"none"),
]
rw0=sum(r[2] for r in L); adj=sum(r[3] for r in L); cnt=sum(r[5] or D(0) for r in L)
assert rw0==D("21896.25"), rw0
assert cnt==D("17662.08"), cnt
assert rw0+adj==cnt, (rw0,adj,cnt)
EXP=D("1804.00")+D("165.00")+D("121.00"); MOVE=D("306.34")
assert EXP-MOVE==D("1783.66")
print(f"Redwing 9/30 {rw0}  adjustments {adj}  count {cnt}  TIES")
print(f"expired {EXP} less moved {MOVE} = net write-off {EXP-MOVE}")

TAG={"done":("done","already corrected"),"jayci":("do","for Jayci"),
     "acct":("acct","with the accountants"),"open":("open","needs a price"),
     "recv":("note","receiving"),"":("","")}
def tr(r):
    med,rwl,rw,a,who,c,det=r
    cls = "act" if who in ("jayci",) else ("done" if who=="done" else ("open" if who in("open","acct","recv") else "zero"))
    t,_=TAG[who]
    return f"""<tr class="{cls}">
 <td class="med">{H(med)}{f'<span class="tag t-{who}">{t}</span>' if t else ''}</td>
 <td class="rw">{H(rwl)}</td>
 <td class="n">{M(rw)}</td>
 <td class="n a">{'&mdash;' if a==0 else M(a)}</td>
 <td class="n">{M(rw+a)}</td>
 <td class="n">{M(c) if c is not None else '<i>not counted</i>'}</td>
 <td class="d">{H(det)}</td></tr>"""
open("rows2.html","w").write("\n".join(tr(r) for r in L))
