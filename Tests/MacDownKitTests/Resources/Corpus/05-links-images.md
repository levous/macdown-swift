# Links and images

Inline: [CommonMark](https://commonmark.org) and [with title](https://commonmark.org "The title").

Reference: [full][ref], [collapsed][], [shortcut], and [case insensitive][REF].

[ref]: https://spec.commonmark.org "Reference title"
[collapsed]: https://example.org/collapsed
[shortcut]: <https://example.org/with spaces>

Autolinks: <https://example.org/path?q=1&r=2> and <hello@example.org>.

Bare URL (needs the Autolink setting): https://example.org and www.example.org.

Relative: [a sibling](02-blocks.md), [a heading](#links-and-images), [up](../README.md).

Empty destination: [nothing]() and [angle]( <> ).

Images: ![inline image](images/block-1.png "Block one") and ![reference image][img].

[img]: images/block-2.png

Image-only paragraph:

![](images/block-3.png)

Image inside a link: [![linked image](images/block-1.png)](https://example.org)

Missing image: ![missing](images/does-not-exist.png)

Brackets that aren't links: [just brackets] and [brackets](
not closed.
