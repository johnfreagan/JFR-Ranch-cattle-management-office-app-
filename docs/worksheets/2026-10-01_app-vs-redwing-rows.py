from decimal import Decimal as D
H = lambda s: (s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;'))
M = lambda x: ('&minus;$' if x < 0 else '$') + f"{abs(x):,.2f}"

# Redwing "Medicine RM Inventory 1/1/1900 to 9/30/2026", account 117500.
# (line label, qty as printed, amount)
RW = [
 ("Biomycin","1.00",D("69.44")), ("Brute","",D("0")), ("Cydectin","2.00",D("1511.96")),
 ("Dectomax","5.00",D("609.50")), ("Draxxin 250 ML","",D("0")), ("Draxxin KP","1.00",D("441.00")),
 ("Enroflox 500 ML","21.00",D("3854.87")), ("Estrumate","1.00",D("105.00")),
 ("Excede 100 ML","24.00",D("5133.40")), ("Excede 250 ML","1.00",D("2596.71")),
 ("Fly Spray","",D("0")), ("Macrosyn 250 ML","",D("373.15")), ("Multi Min","3.00",D("919.03")),
 ("Mycroplasm Vaccine 50 Dose","",D("0")), ("Mycroplasma Vaccine 10 Dose","",D("0")),
 ("One Grass","400.00",D("1804.00")), ("Resflor 250 ML","",D("0")),
 ("Resflor 500 ML","10.00",D("4153.81")), ("Synovex C","110.00",D("121.00")),
 ("Synovex S","150.00",D("165.00")), ("Thiamine","2.00",D("38.38")),
 ("Ultrachoice","",D("0")), ("Valbazen","",D("0")), ("Vira Shield 50 Dose","",D("0")),
 ("Vitamin K","",D("0")),
]
assert sum(a for _,_,a in RW) == D("21896.25"), "Redwing total does not reproduce"

# The opening count as the database holds it, read back 2026-10-01.
# (medication, redwing lines it answers, units, unit label, value or None, note)
APP = [
 ("Biomycin",["Biomycin"],"500 mL",D("69.44"),""),
 ("Brute",["Brute"],"0",None,"counted empty"),
 ("Cydectin",["Cydectin"],"10,000 mL",D("1511.96"),"2 x 5 L"),
 ("Dectomax",["Dectomax"],"2,500 mL",D("609.50"),"5 x 500 mL"),
 ("Draxxin",["Draxxin 250 ML"],"0",None,"counted empty"),
 ("Draxxin KP",["Draxxin KP"],"250 mL",D("441.00"),""),
 ("Enroflox(Baytril)",["Enroflox 500 ML"],"10,500 mL",D("3854.87"),"21 x 500 mL"),
 ("Estrumate",["Estrumate"],"100 mL",D("105.00"),""),
 ("Excede",["Excede 100 ML","Excede 250 ML"],"2,650 mL",D("5668.13"),
  "24 x 100 mL + 1 x 250 mL, all at the 100 mL line's own $2.138917/mL"),
 ("Macrosyn(Draxxin)",["Macrosyn 250 ML"],"0",None,"counted empty"),
 ("Multi Min",["Multi Min"],"2,000 mL",D("1225.37"),"FOUR x 500 mL on the shelf"),
 ("Protivity",["Mycroplasm Vaccine 50 Dose","Mycroplasma Vaccine 10 Dose"],"not counted",None,
  "8 x 10-dose boxes on the shelf, no price known"),
 ("One Grass",["One Grass"],"0",None,"expired, disposed 10/1"),
 ("Resflor",["Resflor 250 ML","Resflor 500 ML"],"5,000 mL",D("4153.81"),"10 x 500 mL"),
 ("Synovex C 100 Ds Prestige",["Synovex C"],"110 doses",D("121.00"),""),
 ("Synovex S",["Synovex S"],"0",None,"expired"),
 ("Thiamine",["Thiamine"],"200 mL",D("38.38"),"2 x 100 mL"),
 ("Ultrachoice 8",["Ultrachoice"],"0",None,"counted empty"),
 ("Vitamin K",["Vitamin K"],"0",None,"counted empty"),
 ("Ivomec Long Range Wormer",[],"0",None,"2 bottles here, Redwing never carried them - going back to the vendor"),
 ("Synovex Primer",[],"0",None,"none on hand, Redwing does not carry it"),
]
assert sum(v for _,_,_,v,_ in APP if v) == D("17798.46"), "app total does not reproduce"

rwmap = {n:(q,a) for n,q,a in RW}
rows, matched = [], set()
for med, lines, units, val, note in APP:
    rwamt = sum(rwmap[l][1] for l in lines)
    rwqty = " + ".join(rwmap[l][0] or "0" for l in lines) if lines else "not carried"
    matched.update(lines)
    var = (val or D(0)) - rwamt
    rows.append((med, " / ".join(lines) or "—", rwqty, rwamt, units, val, var, note,
                 med == "Protivity"))
unmatched = [(n,q,a) for n,q,a in RW if n not in matched]
for n,q,a in unmatched:
    rows.append(("— no medication in the catalog —", n, q or "0", a, "—", None, D(0),
                 "zero on both sides, nothing to do", False))

tot_rw  = sum(r[3] for r in rows)
tot_app = sum(r[5] or D(0) for r in rows)
tot_var = sum(r[6] for r in rows)
assert tot_rw == D("21896.25") and tot_app == D("17798.46")
assert tot_rw + tot_var == tot_app, f"{tot_rw} + {tot_var} != {tot_app}"

def tr(r):
    med, rwline, rwqty, rwamt, units, val, var, note, open_item = r
    cls = "zero" if var == 0 and not open_item else ("open" if open_item else "diff")
    return f"""<tr class="{cls}">
  <td class="med">{H(med)}</td>
  <td class="rw">{H(rwline)}<span class="q">{H(rwqty)}</span></td>
  <td class="n">{M(rwamt)}</td>
  <td class="u">{H(units)}</td>
  <td class="n">{M(val) if val is not None else '&mdash;'}</td>
  <td class="n v">{'&mdash;' if var == 0 else M(var)}</td>
  <td class="why">{H(note)}</td>
</tr>"""

open(__file__.replace("gen.py","rows.html"),"w").write("\n".join(tr(r) for r in rows))
print(f"Redwing  {tot_rw}\napp      {tot_app}\nvariance {tot_var}\nTIES: {tot_rw+tot_var==tot_app}")
print(f"rows: {len(rows)}   with a variance: {sum(1 for r in rows if r[6]!=0)}")
