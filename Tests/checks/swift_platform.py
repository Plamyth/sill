"""Select the platform and DEBUG conditionals used by shared-client fixtures."""


def select_platform(source, *, vision, debug=False, simulator=False):
    conditions = {'os(visionOS)': vision, '!os(visionOS)': not vision, 'DEBUG': debug,
                  'targetEnvironment(simulator)': simulator, 'DEBUG && targetEnvironment(simulator)': debug and simulator}
    output, stack = [], []
    active = True
    for line in source.splitlines(keepends=True):
        directive = line.strip()
        if directive.startswith(('#if ', '#elseif ')):
            command, expression = directive.split(maxsplit=1)
            if expression not in conditions:
                raise ValueError('unsupported Swift fixture condition: ' + expression)
            enabled = conditions[expression]
            if command == '#if':
                stack.append([active, enabled, False])
                active = active and enabled
            else:
                if not stack or stack[-1][2]:
                    raise ValueError('unexpected #elseif')
                parent, taken, _ = stack[-1]
                active = parent and not taken and enabled
                stack[-1][1] = taken or enabled
        elif directive == '#else':
            if not stack or stack[-1][2]:
                raise ValueError('unexpected #else')
            parent, taken, _ = stack[-1]
            active = parent and not taken
            stack[-1][1:] = [True, True]
        elif directive == '#endif':
            if not stack:
                raise ValueError('unexpected #endif')
            active = stack.pop()[0]
        elif active:
            output.append(line)
    if stack:
        raise ValueError('unterminated Swift fixture condition')
    return ''.join(output)
