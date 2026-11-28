-- Pandoc renders autolinks (<https://...>) as \url{...}, which cannot be
-- underlined. Split the link text so the LaTeX writer emits \href{...}{...}
-- instead, letting the PDF link styling apply to every link.
function Link(link)
  if #link.content == 1 and link.content[1].t == "Str"
      and link.content[1].text == link.target then
    local text = link.content[1].text
    link.content = {
      pandoc.Str(text:sub(1, 8)),
      pandoc.RawInline("latex", "\\allowbreak "),
      pandoc.Str(text:sub(9)),
    }
    return link
  end
end
