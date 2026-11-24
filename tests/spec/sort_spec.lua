local sort = require("denote.sort")

describe("denote.sort", function()
  it("sorts files by identifier, title, keywords, and sequence-aware signature", function()
    local input = {
      "/notes/20261123T100003==1=10--zebra__zeta.md",
      "/notes/20261123T100001==1=2--alpha__beta.md",
      "/notes/20261123T100002==1=1--middle__alpha.md",
      "/notes/20261123T100000--no-sig.md",
    }

    local by_id = sort.sort_files(input, "identifier", false)
    eq("/notes/20261123T100000--no-sig.md", by_id[1])
    eq("/notes/20261123T100003==1=10--zebra__zeta.md", by_id[4])

    local by_title = sort.sort_files(input, "title", false)
    eq("/notes/20261123T100001==1=2--alpha__beta.md", by_title[1])
    eq("/notes/20261123T100003==1=10--zebra__zeta.md", by_title[4])

    local by_kw = sort.sort_files(input, "keywords", false)
    eq("/notes/20261123T100002==1=1--middle__alpha.md", by_kw[1])
    eq("/notes/20261123T100000--no-sig.md", by_kw[4]) -- empty keywords sort last

    local by_sig = sort.sort_files(input, "signature", false)
    eq("/notes/20261123T100002==1=1--middle__alpha.md", by_sig[1])
    eq("/notes/20261123T100001==1=2--alpha__beta.md", by_sig[2])
    eq("/notes/20261123T100003==1=10--zebra__zeta.md", by_sig[3])
    eq("/notes/20261123T100000--no-sig.md", by_sig[4]) -- empty signature sorts last

    local by_sig_rev = sort.sort_files(input, "signature", true)
    eq("/notes/20261123T100000--no-sig.md", by_sig_rev[1])
  end)
end)
