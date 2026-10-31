"""Read only the bounded float32 TensorProto subset used by the pinned fixture."""


def float_tensor(data, dimensions):
    if len(data) > 1024 * 1024:
        raise ValueError('Reference tensor budget')
    index, fields = 0, {}

    def varint():
        nonlocal index
        result = 0
        for shift in range(0, 70, 7):
            if index >= len(data):
                raise ValueError('Truncated reference tensor')
            byte = data[index]
            index += 1
            result |= (byte & 127) << shift
            if byte < 128:
                return result
        raise ValueError('Invalid reference integer')

    while index < len(data):
        tag = varint()
        if tag & 7 == 0:
            value = varint()
        elif tag & 7 == 2:
            count = varint()
            if count > len(data) - index:
                raise ValueError('Truncated reference field')
            value = data[index:index + count]
            index += count
        else:
            raise ValueError('Unsupported reference tensor field')
        fields.setdefault(tag >> 3, []).append(value)
    count = 1
    for dimension in dimensions:
        count *= dimension
    raw = fields.get(9, fields.get(4, []))
    if fields.get(1) != dimensions or fields.get(2) != [1] or len(raw) != 1 or len(raw[0]) != count * 4:
        raise ValueError('Unexpected reference tensor shape/type')
    return raw[0]


def reference_image(input_data):
    """Requantize the fixed test tensor into a bordered RGB PNG and exact CHW
    reference. Its 256px sides make the independent center crop unambiguous.
    No copied/user image enters this build-time reference test.
    """
    import struct
    import zlib
    values = struct.unpack('<150528f', input_data)
    means, deviations = [0.485, 0.456, 0.406], [0.229, 0.224, 0.225]
    rgb = bytearray([255, 0, 255]) * (256 * 256)
    tensor = bytearray()
    for channel in range(3):
        for y in range(224):
            for x in range(224):
                original = values[channel * 224 * 224 + y * 224 + x]
                component = min(255, max(0, round((original * deviations[channel] + means[channel]) * 255)))
                rgb[((y + 16) * 256 + x + 16) * 3 + channel] = component
                tensor.extend(struct.pack('<f', (component / 255 - means[channel]) / deviations[channel]))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    rows = b''.join(b'\0' + rgb[y * 768:(y + 1) * 768] for y in range(256))
    png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 256, 256, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
    return png, tensor
