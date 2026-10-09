# Code

    indented code block
    second line

Fenced with backticks:

```
no language
```

```swift
let greeting = "Hello"
print(greeting)
```

~~~python
def tilde():
    return "fenced with tildes"
~~~

````
A longer fence can contain ```
three backticks.
````

```js
// an unclosed fence runs to the end of its container
```

```c++
int alias = 1;  // c++ maps to cpp
```

```objc
NSLog(@"alias for objectivec");
```

```swift:greeting.swift
// info string with a label after a colon
let labeled = true
```

A fence written inside a code span stays inline: `` ```swift `` is not a block.

```
<div>HTML inside code is escaped</div>
&amp; entities stay literal
```

Indented four spaces after a paragraph
    is a lazy continuation, not code.
