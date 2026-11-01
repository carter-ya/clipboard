"""Fixed public test bodies; create only new files in an owned private profile."""
import argparse
from pathlib import Path
from pdf_fixture import text_pdf

TEXT_BODY = (
    'The project team met on Tuesday to review schedules and paperwork. '
    'After inspecting a damaged fuel valve, NASA engineers postponed the Mars '
    'launch until Friday to complete repairs and safety checks.')
PDF_BODY = (
    'Apple Inc. CEO Tim Cook met officials in Tokyo to discuss the company '
    'investment. The meeting focused on the research center and jobs for local engineers.')
AUTOMATIC_BODY = 'Automatic file success fixture. ' + TEXT_BODY


def create(directory):
    directory = Path(directory).resolve(strict=True)
    files = {'private-body.txt': TEXT_BODY.encode(),
             'private-body.pdf': text_pdf(PDF_BODY),
             'automatic-body.txt': AUTOMATIC_BODY.encode()}
    for name, data in files.items():
        with (directory / name).open('xb') as stream:
            stream.write(data)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', required=True)
    create(parser.parse_args().directory)
