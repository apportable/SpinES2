//
//  SpinView.m
//  Spin
//
//  Copyright (c) 2012 Apportable. All rights reserved.
//

#import "SpinView.h"
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

#define HORIZ_SWIPE_DRAG_MIN    24
#define VERT_SWIPE_DRAG_MAX     24
#define TAP_MIN_DRAG            10

@implementation SpinView {
    EAGLContext *context;
    CAEAGLLayer *_eaglLayer;
    
    GLuint _framebuffer;
    GLuint _colorRenderbuffer;
    GLuint _depthRenderBuffer;
    GLuint _vertexBuffer;
    GLuint _vertexColorBuffer;
    GLuint _indexBuffer;
    
    GLuint _positionSlot;
    GLuint _colorSlot;
    GLuint _projectionUniform;
    GLuint _modelViewUniform;
    
    float scale;
    float rotation;
    float rotationSpeed;
    
    BOOL zoomed;
    BOOL moved;
    CGPoint startTouchPosition;
    CGFloat initialDistance;
}

static const char *vertexShaderProgram = ""
    "attribute vec4 position;"
    "attribute vec4 sourceColor;"

    "varying vec4 destinationColor;"

    "uniform mat4 projection;"
    "uniform mat4 modelview;"

    "void main(void) {"
    "    destinationColor = sourceColor;"
    "    gl_Position = projection * modelview * position;"
    "}";

static const char *fragmentShaderProgram = ""
    "varying lowp vec4 destinationColor;"

    "void main(void) {"
    "    gl_FragColor = destinationColor;"
    "}";

static const float RADS_TO_DEGREE = 0.017453292519943f;
static float spinClear = 1.f;

static const GLubyte texture1[4 * 4] =
{
    255, 128,  64, 255,
    64, 128, 255, 255,
    
    64, 128, 255, 255,
    255, 128,  64, 255,
};

static const GLubyte texture2[4 * 4] =
{
    255, 128,  64, 255,
    128, 255,  64, 255,
    
    128, 255,  64, 255,
    255, 128,  64, 255,
};

static const GLubyte colors[8 * 4] =
{
    0, 255, 0, 99,
    0, 225, 0, 255,
    0, 200, 0, 255,
    0, 175, 0, 255,
    
    0, 150, 0, 255,
    0, 125, 0, 255,
    0, 100, 0, 255,
    0, 75, 0, 255,
};

static const GLfloat vertices[8 * 3] =
{
    -1,  1,  1,
    1,  1,  1,
    1, -1,  1,
    -1, -1,  1,
    
    -1,  1, -1,
    1,  1, -1,
    1, -1, -1,
    -1, -1, -1,
};

static const GLfloat textcoords[8 * 2] =
{
    0.0f,   1.0f,
    0.0f,   0.0f,
    1.0f,   0.0f,
    1.0f,   1.0f,
    
    0.0f,   0.0f,
    1.0f,   0.0f,
    0.0f,   1.0f,
    1.0f,   1.0f,
};

static const GLubyte triangles[12 * 3] =
{
    1, 0, 3,
    1, 3, 2,
    
    2, 6, 5,
    2, 5, 1,
    
    7, 4, 5,
    7, 5, 6,
    
    0, 4, 7,
    0, 7, 3,
    
    5, 4, 0,
    5, 0, 1,
    
    3, 7, 6,
    3, 6, 2,
};

#pragma mark - Setup
- (void)setup
{
    [self setupLayer];
    [self setUpBuffers];
    [self compileShaders];
    [self setupDisplayLink];
    [self setUpState];
}

- (void)setupLayer {
    context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:context];
    _eaglLayer = (CAEAGLLayer*) self.layer;
    _eaglLayer.drawableProperties = @{
                                      kEAGLDrawablePropertyRetainedBacking : @NO,
                                      kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8
                                      };
}

- (void)setUpBuffers {
    glGenRenderbuffers(1, &_depthRenderBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _depthRenderBuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, self.frame.size.width, self.frame.size.height);
    
    glGenRenderbuffers(1, &_colorRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderbuffer);
    [context renderbufferStorage:GL_RENDERBUFFER fromDrawable:_eaglLayer];
    
    glGenFramebuffers(1, &_framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorRenderbuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthRenderBuffer);
    
    glGenBuffers(1, &_vertexBuffer);
    glBindBuffer(GL_ARRAY_BUFFER, _vertexBuffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    
    glGenBuffers(1, &_vertexColorBuffer);
    glBindBuffer(GL_ARRAY_BUFFER, _vertexColorBuffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(colors), colors, GL_STATIC_DRAW);
    
    glGenBuffers(1, &_indexBuffer);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _indexBuffer);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(triangles), triangles, GL_STATIC_DRAW);
}

- (GLuint)compileShader:(const char *)shader withType:(GLenum)shaderType
{
    GLuint shaderHandle = glCreateShader(shaderType);
    GLint shaderLength = (GLint)strlen(shader);
    glShaderSource(shaderHandle, 1, &shader, &shaderLength);
    glCompileShader(shaderHandle);
    GLint compileSuccess;
    glGetShaderiv(shaderHandle, GL_COMPILE_STATUS, &compileSuccess);
    if (compileSuccess == GL_FALSE) {
        GLchar messages[256];
        glGetShaderInfoLog(shaderHandle, sizeof(messages), 0, &messages[0]);
        NSLog(@"Error compiling shader:%s\nShader: %s", messages, shader);
        exit(1);
    }
    
    return shaderHandle;
}

- (void)compileShaders
{
    GLuint vertexShader = [self compileShader:vertexShaderProgram withType:GL_VERTEX_SHADER];
    GLuint fragmentShader = [self compileShader:fragmentShaderProgram withType:GL_FRAGMENT_SHADER];
    
    GLuint programHandle = glCreateProgram();
    glAttachShader(programHandle, vertexShader);
    glAttachShader(programHandle, fragmentShader);
    glLinkProgram(programHandle);
    
    GLint linkSuccess;
    glGetProgramiv(programHandle, GL_LINK_STATUS, &linkSuccess);
    if (linkSuccess == GL_FALSE) {
        GLchar messages[256];
        GLint length = 0;
        glGetProgramiv(programHandle, GL_INFO_LOG_LENGTH, &length);
        glGetProgramInfoLog(programHandle, sizeof(messages), &length, &messages[0]);
        NSLog(@"Error linking program: %s", messages);
        exit(1);
    }
    glUseProgram(programHandle);
    _positionSlot = glGetAttribLocation(programHandle, "position");
    _colorSlot = glGetAttribLocation(programHandle, "sourceColor");
    glEnableVertexAttribArray(_positionSlot);
    glEnableVertexAttribArray(_colorSlot);
    
    _projectionUniform = glGetUniformLocation(programHandle, "projection");
    _modelViewUniform = glGetUniformLocation(programHandle, "modelview");
}

- (void)setupDisplayLink {
    CADisplayLink* displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(render:)];
    [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
}

- (void)setUpState
{
    rotation = 0.1f;
    rotationSpeed = 3.0f;
    scale = 1.0f;
    
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_CULL_FACE);
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_SRC_COLOR);
    
    glClearColor(spinClear * 0.1f, spinClear * 0.1f, spinClear * 0.1f, 1.0f);
}

#pragma mark - Rendering
- (void)render:(CADisplayLink*)displayLink
{
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);
    
    float width = self.frame.size.width;
    float height = self.frame.size.width;
    
    GLfloat projectionMatrix[16] = {0};
    [self.class projectionMatrix:projectionMatrix fovy:20 aspect:width/height znear:5 zfar:15];
    glUniformMatrix4fv(_projectionUniform, 1, GL_FALSE, projectionMatrix);
    
    GLfloat modelViewMatrix[16] = {0};
    [self.class populateWithIdentity:modelViewMatrix];
    [self.class translateMatrix:modelViewMatrix x:0 y:0 z:-10];
    [self.class rotateMatrix:modelViewMatrix angleInDegrees:30 x:1 y:0 z:0];
    [self.class scaleMatrix:modelViewMatrix x:scale y:scale z:scale];
    [self.class rotateMatrix:modelViewMatrix angleInDegrees:rotation x:0 y:1 z:0];
    
    glUniformMatrix4fv(_modelViewUniform, 1, GL_FALSE, modelViewMatrix);
    glViewport(0, 0, width, height);
    
    glEnableVertexAttribArray(_positionSlot);
    glEnableVertexAttribArray(_colorSlot);
    
    glBindBuffer(GL_ARRAY_BUFFER, _vertexBuffer);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _indexBuffer);
    glVertexAttribPointer(_positionSlot, 3, GL_FLOAT, GL_FALSE, 0, 0);
    
    glBindBuffer(GL_ARRAY_BUFFER, _vertexColorBuffer);
    glVertexAttribPointer(_colorSlot, 4, GL_UNSIGNED_BYTE, GL_TRUE, 0, 0);
    
    glDrawElements(GL_TRIANGLES, sizeof(triangles)/sizeof(triangles[0]), GL_UNSIGNED_BYTE, 0);
    
    rotation += rotationSpeed;
    
    glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderbuffer);
    
    [context presentRenderbuffer:GL_RENDERBUFFER];
}

#pragma mark - init and dealloc
- (id)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (self)
    {
        [self setup];
    }
    return self;
}

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
    {
        [self setup];
    }
    return self;
}

- (void)dealloc
{
    [context release];
    context = nil;
    [super dealloc];
}

#pragma mark - UIView Methods
+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (void)setBounds:(CGRect)bounds
{
    [super setBounds:bounds];
    CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;
    [context renderbufferStorage:GL_RENDERBUFFER fromDrawable:eaglLayer];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    moved = NO;
    switch ([touches count]) {
        case 1:
        {
            // single touch
            UITouch * touch = [touches anyObject];
            startTouchPosition = [touch locationInView:self];
            initialDistance = -1;
            break;
        }
        default:
        {
            // multi touch
            NSArray *touchArray = [touches allObjects];
            NSLog(@"multi touch detected %d", [touches count]);
            UITouch *touch1 = [touchArray objectAtIndex:0];
            NSLog(@"touch1 %@", touch1);
			UITouch *touch2 = [touchArray objectAtIndex:1];
            NSLog(@"touch2 %@", touch2);
            initialDistance = [self distanceBetweenTwoPoints:[touch1 locationInView:self]
                                                     toPoint:[touch2 locationInView:self]];
            NSLog(@"Multi touch start with initial distance %d", (int)initialDistance);
            break;
        }
            
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    UITouch *touch1 = [[touches allObjects] objectAtIndex:0];
    
    if (zoomed && ([touches count] == 1)) {
        CGPoint pos = [touch1 locationInView:self];
        self.transform = CGAffineTransformTranslate(self.transform, pos.x - startTouchPosition.x, pos.y - startTouchPosition.y);
        moved = YES;
        return;
    }
    
    if ((initialDistance > 0) && ([touches count] > 1)) {
        UITouch *touch2 = [[touches allObjects] objectAtIndex:1];
        CGFloat currentDistance = [self distanceBetweenTwoPoints:[touch1 locationInView:self]
                                                         toPoint:[touch2 locationInView:self]];
        CGFloat movement = currentDistance - initialDistance;
        NSLog(@"Touch moved: %d", (int)movement);
        if (movement != 0) {
            scale *= pow(2.0f, movement / 100);
            if (scale > 2.0) scale = 2;
            if (scale < 0.1) scale = 0.1;
        }
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    UITouch *touch1 = [[touches allObjects] objectAtIndex:0];
    if ([touches count] == 1) {
        if ([touch1 tapCount] > 1) {
            NSLog(@"Double tap");
            scale = 1.0f;
            rotation = 3.0f;
            return;
        }
        CGPoint currentTouchPosition = [touch1 locationInView:self];
        
        float deltaX = fabsf(startTouchPosition.x - currentTouchPosition.x);
        float deltaY = fabsf(startTouchPosition.y - currentTouchPosition.y);
        // If the swipe tracks correctly.
        if ((deltaX >= HORIZ_SWIPE_DRAG_MIN) && (deltaY <= VERT_SWIPE_DRAG_MAX))
        {
            // It appears to be a swipe.
            float movement = startTouchPosition.x - currentTouchPosition.x;
            if (movement < 0)
            {
                NSLog(@"Swipe Right");
                rotationSpeed += pow(2.0f, -movement / 100);
            }
            else
            {
                rotationSpeed -= pow(2.0f, movement / 100);
                NSLog(@"Swipe Left");
            }
        }
        else if (!moved && ((deltaX <= TAP_MIN_DRAG) && (deltaY <= TAP_MIN_DRAG)) )
        {
            // Process a tap event.
            NSLog(@"Tap");
        }
    }
    else {
        // multi-touch
        UITouch *touch2 = [[touches allObjects] objectAtIndex:1];
        CGFloat finalDistance = [self distanceBetweenTwoPoints:[touch1 locationInView:self]
                                                       toPoint:[touch2 locationInView:self]];
        CGFloat movement = finalDistance - initialDistance;
        NSLog(@"Final Distance: %d, movement=%d",(int)finalDistance,(int)movement);
        if (movement != 0) {
            NSLog(@"Movement: %d", (int)movement);
        }
    }
}

#pragma mark - Math Helpers

// All matrix math helpers assume a 4x4 column major order matrix

- (CGFloat)distanceBetweenTwoPoints:(CGPoint)fromPoint toPoint:(CGPoint)toPoint {
	float x = toPoint.x - fromPoint.x;
    float y = toPoint.y - fromPoint.y;
    NSLog(@"distanceBetweenTwoPoints: toPoint = %d %d, fromPoint = %d %d, x = %d, y = %d, sqr = %d", (int)toPoint.x, (int)toPoint.y, (int)fromPoint.x, (int)fromPoint.y, (int)x, (int)y, (int)(x*x+y*y));
    
    return sqrt(x * x + y * y);
}

+ (void)populateWithIdentity:(GLfloat *)matrix
{
    matrix[0] = 1;
	matrix[1] = 0;
	matrix[2] = 0;
	matrix[3] = 0;
	
	matrix[4] = 0;
	matrix[5] = 1;
	matrix[6] = 0;
	matrix[7] = 0;
	
	matrix[8] = 0;
	matrix[9] = 0;
	matrix[10] = 1;
	matrix[11] = 0;
	
	matrix[12] = 0;
	matrix[13] = 0;
	matrix[14] = 0;
	matrix[15] = 1;
}

+ (void)projectionMatrix:(GLfloat *)matrix fovy:(GLfloat)fovy aspect:(GLfloat)aspect znear:(GLfloat)zNear zfar:(GLfloat)zFar
{
    GLfloat xmin, xmax, ymin, ymax;
    ymax = zNear * tan(fovy * M_PI / 360.0);
    ymin = -ymax;
    xmin = ymin * aspect;
    xmax = ymax * aspect;
    
    [self projectionMatrixFrustum:matrix left:xmin right:xmax bottom:ymin top:ymax near:zNear far:zFar];
}

+ (void)projectionMatrixFrustum:(GLfloat *)matrix left:(GLfloat)left right:(GLfloat)right bottom:(GLfloat)bottom top:(GLfloat)top near:(GLfloat)near far:(GLfloat)far
{
    [self populateWithIdentity:matrix];
	
    matrix[0] = (2.0 * near) / (right - left);
	matrix[8] = (right + left) / (right - left);
	matrix[5] = (2.0 * near) / (top - bottom);
	matrix[9] = (top + bottom) / (top - bottom);
	matrix[10] = -(far + near) / (far - near);
	matrix[14] = -(2.0 * far * near) / (far - near);
	matrix[11] = -1.0;
	matrix[15] = 0.0;
}

+ (void)rotateMatrix:(GLfloat *)matrix angleInDegrees:(GLfloat)angle x:(GLfloat)x y:(GLfloat)y z:(GLfloat)z
{
    GLfloat rotationMatrix[16] = {0};
    [self populateWithIdentity:rotationMatrix];
    
    GLfloat magnitude = sqrt(pow(x, 2) + pow(y, 2) + pow(z, 2));
    x /= magnitude;
    y /= magnitude;
    z /= magnitude;
    
    GLfloat angleInRads = angle * RADS_TO_DEGREE;
    GLfloat c = cos(angleInRads);
    GLfloat s = sin(angleInRads);
    
    rotationMatrix[0] = pow(x, 2) * (1 - c) + c;
    rotationMatrix[1] = y * x * (1 - c) + z * s;
    rotationMatrix[2] = x * z * (1 - c) - y * s;
    rotationMatrix[3] = 0.0f;
    
    rotationMatrix[4] = x * y * (1 - c) - z * s;
    rotationMatrix[5] = pow(y, 2) * (1 - c) + c;
    rotationMatrix[6] = y * z * (1 - c) + x * s;
    rotationMatrix[7] = 0.0f;
    
    rotationMatrix[8] = x * z * (1 - c) + y * s;
    rotationMatrix[9] = y * z * (1 - c) - x * s;
    rotationMatrix[10] = pow(z, 2) * (1 - c) + c;
    rotationMatrix[11] = 0.0f;
    
    rotationMatrix[12] = 0.0f;
    rotationMatrix[13] = 0.0f;
    rotationMatrix[14] = 0.0f;
    rotationMatrix[15] = 1.0f;
    
    [self multiplyIntoResultMatrix:matrix matrix1:matrix matrix2:rotationMatrix];
}

+ (void)translateMatrix:(GLfloat *)matrix x:(GLfloat)x y:(GLfloat)y z:(GLfloat)z
{
    GLfloat translationMatrix[16] = {0};
    [self populateWithIdentity:translationMatrix];
    
    translationMatrix[12] = x;
    translationMatrix[13] = y;
    translationMatrix[14] = z;
    
    [self multiplyIntoResultMatrix:matrix matrix1:matrix matrix2:translationMatrix];
}

+ (void)scaleMatrix:(GLfloat *)matrix x:(GLfloat)x y:(GLfloat)y z:(GLfloat)z
{
    GLfloat scaleMatrix[16] = {0};
    [self populateWithIdentity:scaleMatrix];
    
    matrix[0] = x;
    matrix[5] = y;
    matrix[10] = z;
    
    [self multiplyIntoResultMatrix:matrix matrix1:matrix matrix2:scaleMatrix];
}

+ (void)multiplyIntoResultMatrix:(GLfloat *)matrix matrix1:(GLfloat *)matrix1 matrix2:(GLfloat *)matrix2
{
    GLfloat result[16] = {0};
    
	result[0] = matrix1[0] * matrix2[0] + matrix1[4] * matrix2[1] + matrix1[8] * matrix2[2] + matrix1[12] * matrix2[3];
	result[1] = matrix1[1] * matrix2[0] + matrix1[5] * matrix2[1] + matrix1[9] * matrix2[2] + matrix1[13] * matrix2[3];
	result[2] = matrix1[2] * matrix2[0] + matrix1[6] * matrix2[1] + matrix1[10] * matrix2[2] + matrix1[14] * matrix2[3];
	result[3] = matrix1[3] * matrix2[0] + matrix1[7] * matrix2[1] + matrix1[11] * matrix2[2] + matrix1[15] * matrix2[3];
    
	result[4] = matrix1[0] * matrix2[4] + matrix1[4] * matrix2[5] + matrix1[8] * matrix2[6] + matrix1[12] * matrix2[7];
	result[5] = matrix1[1] * matrix2[4] + matrix1[5] * matrix2[5] + matrix1[9] * matrix2[6] + matrix1[13] * matrix2[7];
	result[6] = matrix1[2] * matrix2[4] + matrix1[6] * matrix2[5] + matrix1[10] * matrix2[6] + matrix1[14] * matrix2[7];
	result[7] = matrix1[3] * matrix2[4] + matrix1[7] * matrix2[5] + matrix1[11] * matrix2[6] + matrix1[15] * matrix2[7];
    
	result[8] = matrix1[0] * matrix2[8] + matrix1[4] * matrix2[9] + matrix1[8] * matrix2[10] + matrix1[12] * matrix2[11];
	result[9] = matrix1[1] * matrix2[8] + matrix1[5] * matrix2[9] + matrix1[9] * matrix2[10] + matrix1[13] * matrix2[11];
	result[10] = matrix1[2] * matrix2[8] + matrix1[6] * matrix2[9] + matrix1[10] * matrix2[10] + matrix1[14] * matrix2[11];
	result[11] = matrix1[3] * matrix2[8] + matrix1[7] * matrix2[9] + matrix1[11] * matrix2[10] + matrix1[15] * matrix2[11];
    
	result[12] = matrix1[0] * matrix2[12] + matrix1[4] * matrix2[13] + matrix1[8] * matrix2[14] + matrix1[12] * matrix2[15];
	result[13] = matrix1[1] * matrix2[12] + matrix1[5] * matrix2[13] + matrix1[9] * matrix2[14] + matrix1[13] * matrix2[15];
	result[14] = matrix1[2] * matrix2[12] + matrix1[6] * matrix2[13] + matrix1[10] * matrix2[14] + matrix1[14] * matrix2[15];
	result[15] = matrix1[3] * matrix2[12] + matrix1[7] * matrix2[13] + matrix1[11] * matrix2[14] + matrix1[15] * matrix2[15];
    
    memcpy(matrix, result, 16 * sizeof(GLfloat));
}


@end
