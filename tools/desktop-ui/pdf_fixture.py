"""Tiny, entirely synthetic text PDFs for independent native regression fixtures."""

SUMMARY_PDF_LEAD = 'This synthetic PDF excerpt stays on this device.'
SUMMARY_PDF_BODY = SUMMARY_PDF_LEAD + ' Private PDF context.' * 10


def text_pdf(text, pages=1, unicode_mapping=False):
    escaped = text.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')
    stream = ('BT /F1 12 Tf 30 740 Td (' + escaped + ') Tj ET').encode('ascii')
    font = b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica'
    if unicode_mapping:
        font += b' /ToUnicode 6 0 R'
    font += b' >>'
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [' + b'3 0 R ' * pages + b'] /Count ' + str(pages).encode() + b' >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
               font, b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream']
    if unicode_mapping:
        mapping = (b'/CIDInit /ProcSet findresource begin 12 dict begin begincmap\n'
                   b'/CIDSystemInfo << /Registry (Synthetic) /Ordering (Unicode) /Supplement 0 >> def\n'
                   b'/CMapName /Synthetic def /CMapType 2 def\n'
                   b'1 begincodespacerange <00> <FF> endcodespacerange\n'
                   b'2 beginbfchar <41> <4E2D> <42> <D83DDE00> endbfchar\n'
                   b'endcmap CMapName currentdict /CMap defineresource pop end end')
        objects.append(b'<< /Length ' + str(len(mapping)).encode() + b' >>\nstream\n' + mapping + b'\nendstream')
    pdf, offsets = b'%PDF-1.4\n', [0]
    for number, body in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf += str(number).encode() + b' 0 obj\n' + body + b'\nendobj\n'
    start = len(pdf)
    pdf += b'xref\n0 ' + str(len(offsets)).encode() + b'\n0000000000 65535 f \n'
    for offset in offsets[1:]:
        pdf += f'{offset:010d} 00000 n \n'.encode()
    return (pdf + b'trailer\n<< /Size ' + str(len(offsets)).encode() + b' /Root 1 0 R >>\nstartxref\n'
            + str(start).encode() + b'\n%%EOF\n')


if __name__ == '__main__':
    import argparse
    from pathlib import Path
    parser = argparse.ArgumentParser()
    parser.add_argument('--private-summary-fixture', required=True)
    args = parser.parse_args()
    # Never overwrite an existing file; the native probe owns the destination.
    with Path(args.private_summary_fixture).open('xb') as file:
        file.write(text_pdf(SUMMARY_PDF_BODY))
