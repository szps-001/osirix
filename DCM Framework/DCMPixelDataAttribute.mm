/*=========================================================================
  Program:   OsiriX

  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - GPL
  
  See http://www.osirix-viewer.com/copyright.html for details.

     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
=========================================================================*/


#import "DCMPixelDataAttribute.h"
#import "DCM.h"
#import "jpeglib12.h"
#import <stdio.h>
#import "jpegdatasrc.h"
#import "DCMPixelDataAttributeJPEG8.h"
#import "DCMPixelDataAttributeJPEG12.h"
#import "DCMPixelDataAttributeJPEG16.h"
#import "Accelerate/Accelerate.h"
//#import "DCMPixelDataAttributeJPEG2000.h"

#import "jasper.h"

static int UseOpenJpeg = 0;
static int JasperInitialized = 0;

#if __ppc__

union vectorShort {
    vector short shortVec;
    short scalar[8];
};

union vectorChar {
    vector unsigned char byteVec;
    unsigned scalar[16];
};


union vectorLong {
    vector int longVec;
    short scalar[4];
};

 union  vectorFloat {
    vector float floatVec;
    float scalar[4];
};


void SwapShorts( register vector unsigned short *unaligned_input, register long size)
{
	 register long						i = size / 8;
	 register vector unsigned char		identity = vec_lvsl(0, (int*) NULL );
	 register vector unsigned char		byteSwapShorts = vec_xor( identity, vec_splat_u8(sizeof( short) - 1) );
	
	while(i-- > 0)
	{
		*unaligned_input++ = vec_perm( *unaligned_input, *unaligned_input, byteSwapShorts);
	}
}

void SwapLongs( register vector unsigned int *unaligned_input, register long size)
{
	 register long i = size / 4;
	 register vector unsigned char identity = vec_lvsl(0, (int*) NULL );
	 register vector unsigned char byteSwapLongs = vec_xor( identity, vec_splat_u8(sizeof( int )- 1 ) );
	 while(i-- > 0)
	 {
	 *unaligned_input++ = vec_perm( *unaligned_input, *unaligned_input, byteSwapLongs);
	 }
}

#endif

//altivec
#define dcmHasAltiVecMask    ( 1 << gestaltPowerPCHasVectorInstructions )  // used in  looking for a g4 

short DCMHasAltiVec()
{
	Boolean hasAltiVec = 0;
	OSErr      err;       
	SInt32      ppcFeatures;
	
	err = Gestalt ( gestaltPowerPCProcessorFeatures, &ppcFeatures );       
	if ( err == noErr)       
	{             
		if ( ( ppcFeatures & dcmHasAltiVecMask) != 0 )
		{
			hasAltiVec = 1;
		}
	}       
	return hasAltiVec; 
}

unsigned short readUint16(const unsigned char *data)
{
  return (((unsigned short)(*data) << 8) | ((unsigned short)(*(data+1))));
}

unsigned char scanJpegDataForBitDepth(
  const unsigned char *data,
  const long fragmentLength)
{
  long offset = 0;
  while(offset+4 < fragmentLength)
  {
    switch(readUint16(data+offset))
    {
      case 0xffc0: // SOF_0: JPEG baseline
        return data[offset+4];
        /* break; */
      case 0xffc1: // SOF_1: JPEG extended sequential DCT
        return data[offset+4];
        /* break; */
      case 0xffc2: // SOF_2: JPEG progressive DCT
        return data[offset+4];
        /* break; */
      case 0xffc3 : // SOF_3: JPEG lossless sequential
        return data[offset+4];
        /* break; */
      case 0xffc5: // SOF_5: differential (hierarchical) extended sequential, Huffman
        return data[offset+4];
        /* break; */
      case 0xffc6: // SOF_6: differential (hierarchical) progressive, Huffman
        return data[offset+4];
        /* break; */
      case 0xffc7: // SOF_7: differential (hierarchical) lossless, Huffman
        return data[offset+4];
        /* break; */
      case 0xffc8: // Reserved for JPEG extentions
        offset += readUint16(data+offset+2)+2;
        break;
      case 0xffc9: // SOF_9: extended sequential, arithmetic
        return data[offset+4];
        /* break; */
      case 0xffca: // SOF_10: progressive, arithmetic
        return data[offset+4];
        /* break; */
      case 0xffcb: // SOF_11: lossless, arithmetic
        return data[offset+4];
        /* break; */
      case 0xffcd: // SOF_13: differential (hierarchical) extended sequential, arithmetic
        return data[offset+4];
        /* break; */
      case 0xffce: // SOF_14: differential (hierarchical) progressive, arithmetic
        return data[offset+4];
        /* break; */
      case 0xffcf: // SOF_15: differential (hierarchical) lossless, arithmetic
        return data[offset+4];
        /* break; */
      case 0xffc4: // DHT
        offset += readUint16(data+offset+2)+2;
        break;
      case 0xffcc: // DAC
        offset += readUint16(data+offset+2)+2;
        break;
      case 0xffd0: // RST m
      case 0xffd1:
      case 0xffd2:
      case 0xffd3:
      case 0xffd4:
      case 0xffd5:
      case 0xffd6:
      case 0xffd7:
        offset +=2;
        break;
      case 0xffd8: // SOI
        offset +=2;
        break;
      case 0xffd9: // EOI
        offset +=2;
        break;
      case 0xffda: // SOS
        offset += readUint16(data+offset+2)+2;
        break;
      case 0xffdb: // DQT
        offset += readUint16(data+offset+2)+2;
        break;
      case 0xffdc: // DNL
        offset += readUint16(data+offset+2)+2;
        break;
      case 0xffdd: // DRI
        offset += readUint16(data+offset+2)+2;
        break;
      case 0xffde: // DHP
        offset += readUint16(data+offset+2)+2;
        break;
      case 0xffdf: // EXP
        offset += readUint16(data+offset+2)+2;
        break;
      case 0xffe0: // APPn
      case 0xffe1:
      case 0xffe2:
      case 0xffe3:
      case 0xffe4:
      case 0xffe5:
      case 0xffe6:
      case 0xffe7:
      case 0xffe8:
      case 0xffe9:
      case 0xffea:
      case 0xffeb:
      case 0xffec:
      case 0xffed:
      case 0xffee:
      case 0xffef:
        offset += readUint16(data+offset+2)+2;
        break;
      case 0xfff0: // JPGn
      case 0xfff1:
      case 0xfff2:
      case 0xfff3:
      case 0xfff4:
      case 0xfff5:
      case 0xfff6:
      case 0xfff7:
      case 0xfff8:
      case 0xfff9:
      case 0xfffa:
      case 0xfffb:
      case 0xfffc:
      case 0xfffd:
        offset += readUint16(data+offset+2)+2;
        break;
      case 0xfffe: // COM
        offset += readUint16(data+offset+2)+2;
        break;
      case 0xff01: // TEM
        break;
      default:
        if ((data[offset]==0xff) && (data[offset+1]>2) && (data[offset+1] <= 0xbf)) // RES reserved markers
        {
          offset += 2;
        }
        else return 0; // syntax error, stop parsing
        break;
    }
  } // while
  return 0; // no SOF marker found
}

//JPEG 2000


/******************************************************************************\
* Miscellaneous functions.
\******************************************************************************/

//static int pnm_getuint(jas_stream_t *in, int wordsize, uint_fast32_t *val);
//
//static int pnm_getsint(jas_stream_t *in, int wordsize, int_fast32_t *val)
//{
//	uint_fast32_t tmpval;
//
//	if (pnm_getuint(in, wordsize, &tmpval)) {
//		return -1;
//	}
//	if (val) {
//		assert((tmpval & (1 << (wordsize - 1))) == 0);
//		*val = tmpval;
//	}
//
//	return 0;
//}
//
//static int pnm_getuint(jas_stream_t *in, int wordsize, uint_fast32_t *val)
//{
//	uint_fast32_t tmpval;
//	int c;
//	int n;
//
//	tmpval = 0;
//	n = (wordsize + 7) / 8;
//	while (--n >= 0) {
//		if ((c = jas_stream_getc(in)) == EOF) {
//			return -1;
//		}
//		tmpval = (tmpval << 8) | c;
//	}
//	tmpval &= (((uint_fast64_t) 1) << wordsize) - 1;
//	if (val) {
//		*val = tmpval;
//	}
//
//	return 0;
//}

#include "openjpeg.h"
/**
sample error callback expecting a FILE* client object
*/
void error_callback(const char *msg, void *a) {
	NSLog( @"%s", msg);
}
/**
sample warning callback expecting a FILE* client object
*/
void warning_callback(const char *msg, void *a) {
	NSLog( @"%s", msg);
}
/**
sample debug callback expecting no client object
*/
void info_callback(const char *msg, void *a) {
//	NSLog( @"%s", msg);
}

static inline int int_ceildivpow2(int a, int b) {
	return (a + (1 << b) - 1) >> b;
}

bool dcm_read_JPEG2000_file (void* raw, char *inputdata, size_t inputlength)
{
  opj_dparameters_t parameters;  /* decompression parameters */
  opj_event_mgr_t event_mgr;    /* event manager */
  opj_image_t *image;
  opj_dinfo_t* dinfo;  /* handle to a decompressor */
  opj_cio_t *cio;
  unsigned char *src = (unsigned char*)inputdata; 
  int file_length = inputlength;

  /* configure the event callbacks (not required) */
  memset(&event_mgr, 0, sizeof(opj_event_mgr_t));
  event_mgr.error_handler = error_callback;
  event_mgr.warning_handler = warning_callback;
  event_mgr.info_handler = info_callback;

  /* set decoding parameters to default values */
  opj_set_default_decoder_parameters(&parameters);
 
   // default blindly copied
   parameters.cp_layer=0;
   parameters.cp_reduce=0;
//   parameters.decod_format=-1;
//   parameters.cod_format=-1;

      /* JPEG-2000 codestream */
    parameters.decod_format = 0;
  parameters.cod_format = 1;

      /* get a decoder handle */
      dinfo = opj_create_decompress(CODEC_J2K);

      /* catch events using our callbacks and give a local context */
      opj_set_event_mgr((opj_common_ptr)dinfo, &event_mgr, NULL);

      /* setup the decoder decoding parameters using user parameters */
      opj_setup_decoder(dinfo, &parameters);

      /* open a byte stream */
      cio = opj_cio_open((opj_common_ptr)dinfo, src, file_length);

      /* decode the stream and fill the image structure */
      image = opj_decode(dinfo, cio);
      if(!image) {
        opj_destroy_decompress(dinfo);
        opj_cio_close(cio);
        return 1;
      }
      
      /* close the byte stream */
      opj_cio_close(cio);

  /* free the memory containing the code-stream */
  
   // Copy buffer
   for (int compno = 0; compno < image->numcomps; compno++)
   {
      opj_image_comp_t *comp = &image->comps[compno];

      int w = image->comps[compno].w;
      int wr = int_ceildivpow2(image->comps[compno].w, image->comps[compno].factor);

      //int h = image.comps[compno].h;
      int hr = int_ceildivpow2(image->comps[compno].h, image->comps[compno].factor);

      if (comp->prec <= 8)
      {
         uint8_t *data8 = (uint8_t*)raw + compno;
         for (int i = 0; i < wr * hr; i++)
         {
            int v = image->comps[compno].data[i / wr * w + i % wr];
            *data8 = (uint8_t)v;
            data8 += image->numcomps;
         }
      }
      else if (comp->prec <= 16)
      {
         uint16_t *data16 = (uint16_t*)raw + compno;
         for (int i = 0; i < wr * hr; i++)
         {
            int v = image->comps[compno].data[i / wr * w + i % wr];
            *data16 = (uint16_t)v;
            data16 += image->numcomps;
         }
      }
      else
      {
         uint32_t *data32 = (uint32_t*)raw + compno;
         for (int i = 0; i < wr * hr; i++)
         {
            int v = image->comps[compno].data[i / wr * w + i % wr];
            *data32 = (uint32_t)v;
            data32 += image->numcomps;
         }
      }
      //free(image.comps[compno].data);
   }

  /* free remaining structures */
  if(dinfo) {
    opj_destroy_decompress(dinfo);
  }

  /* free image data structure */
  opj_image_destroy(image);

  return true;
}

template<typename T>
void rawtoimage_fill(T *inputbuffer, int w, int h, int numcomps, opj_image_t *image, int pc)
{
  T *p = inputbuffer;
  if( pc )
    {
    for(int compno = 0; compno < numcomps; compno++)
      {
      for (int i = 0; i < w * h; i++)
        {
        /* compno : 0 = GREY, (0, 1, 2) = (R, G, B) */
        image->comps[compno].data[i] = *p;
        ++p;
        }
      }
    }
  else
    {
    for (int i = 0; i < w * h; i++)
      {
      for(int compno = 0; compno < numcomps; compno++)
        {
        /* compno : 0 = GREY, (0, 1, 2) = (R, G, B) */
        image->comps[compno].data[i] = *p;
        ++p;
        }
      }
    }
}


opj_image_t* rawtoimage(char *inputbuffer, opj_cparameters_t *parameters,
  int fragment_size, int image_width, int image_height, int sample_pixel,
  int bitsallocated, int bitsstored, int sign, int quality, int pc)
{
  (void)quality;
  int w, h;
  int numcomps;
  OPJ_COLOR_SPACE color_space;
  opj_image_cmptparm_t cmptparm[3]; /* maximum of 3 components */
  opj_image_t * image = NULL;

  assert( sample_pixel == 1 || sample_pixel == 3 );
  if( sample_pixel == 1 )
    {
    numcomps = 1;
    color_space = CLRSPC_GRAY;
    }
  else // sample_pixel == 3
    {
    numcomps = 3;
    color_space = CLRSPC_SRGB;
    /* Does OpenJPEg support: CLRSPC_SYCC ?? */
    }
  if( bitsallocated % 8 != 0 )
    {
    return 0;
    }
  assert( bitsallocated % 8 == 0 );
  // eg. fragment_size == 63532 and 181 * 117 * 3 * 8 == 63531 ...
  assert( ((fragment_size + 1)/2 ) * 2 == ((image_height * image_width * numcomps * (bitsallocated/8) + 1)/ 2 )* 2 );
  int subsampling_dx = parameters->subsampling_dx;
  int subsampling_dy = parameters->subsampling_dy;

  // FIXME
  w = image_width;
  h = image_height;

  /* initialize image components */
  memset(&cmptparm[0], 0, 3 * sizeof(opj_image_cmptparm_t));
  //assert( bitsallocated == 8 );
  for(int i = 0; i < numcomps; i++) {
    cmptparm[i].prec = bitsstored;
    cmptparm[i].bpp = bitsallocated;
    cmptparm[i].sgnd = sign;
    cmptparm[i].dx = subsampling_dx;
    cmptparm[i].dy = subsampling_dy;
    cmptparm[i].w = w;
    cmptparm[i].h = h;
  }

  /* create the image */
  image = opj_image_create(numcomps, &cmptparm[0], color_space);
  if(!image) {
    return NULL;
  }
  /* set image offset and reference grid */
  image->x0 = parameters->image_offset_x0;
  image->y0 = parameters->image_offset_y0;
  image->x1 = parameters->image_offset_x0 + (w - 1) * subsampling_dx + 1;
  image->y1 = parameters->image_offset_y0 + (h - 1) * subsampling_dy + 1;

  /* set image data */

  //assert( fragment_size == numcomps*w*h*(bitsallocated/8) );
  if (bitsallocated <= 8)
    {
    if( sign )
      {
      rawtoimage_fill<int8_t>((int8_t*)inputbuffer,w,h,numcomps,image,pc);
      }
    else
      {
      rawtoimage_fill<uint8_t>((uint8_t*)inputbuffer,w,h,numcomps,image,pc);
      }
    }
  else if (bitsallocated <= 16)
    {
    if( sign )
      {
      rawtoimage_fill<int16_t>((int16_t*)inputbuffer,w,h,numcomps,image,pc);
      }
    else
      {
      rawtoimage_fill<uint16_t>((uint16_t*)inputbuffer,w,h,numcomps,image,pc);
      }
    }
  else if (bitsallocated <= 32)
    {
    if( sign )
      {
      rawtoimage_fill<int32_t>((int32_t*)inputbuffer,w,h,numcomps,image,pc);
      }
    else
      {
      rawtoimage_fill<uint32_t>((uint32_t*)inputbuffer,w,h,numcomps,image,pc);
      }
    }
  else
    {
    return NULL;
    }

  return image;
}
/////////


@implementation DCMPixelDataAttribute

@synthesize rows = _rows;
@synthesize columns = _columns;
@synthesize numberOfFrames = _numberOfFrames;
@synthesize transferSyntax;
@synthesize samplesPerPixel = _samplesPerPixel;
@synthesize bytesPerSample = _bytesPerSample;
@synthesize pixelDepth = _pixelDepth;
@synthesize isShort = _isShort;
@synthesize compression = _compression;
@synthesize isDecoded = _isDecoded;

+ (void) setUseOpenJpeg:(int) b
{
	UseOpenJpeg = b;
}

- (void)dealloc
{
	[singleThread release];
	[transferSyntax release];
	[_framesDecoded release];
	[super dealloc];
}

- (id) initWithAttributeTag:(DCMAttributeTag *)tag 
			vr:(NSString *)vr 
			length:(long) vl 
			data:(DCMDataContainer *)dicomData 
			specificCharacterSet:(DCMCharacterSet *)specificCharacterSet
			transferSyntax:(DCMTransferSyntax *)ts
			dcmObject:(DCMObject *)dcmObject
			decodeData:(BOOL)decodeData{

	singleThread = [[NSLock alloc] init];

	NSString *theVR = @"OW";
	BOOL forImplicitUseOW = NO;
	_dcmObject = dcmObject;
	_isSigned = NO;
	_framesCreated = NO;
	
	_pixelDepth = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"BitsStored"]] value] intValue];
	_bitsStored = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"BitsAllocated"]] value] intValue];
		
	if ( ts.isExplicit && ([vr isEqualToString:@"OB"] || [vr isEqualToString:@"OW"]))
		theVR = vr;	
	else if ( _bitsStored <= 8 || dicomData.isEncapsulated ) 
		theVR = @"OB";
	else {
		forImplicitUseOW = YES;
		theVR = @"OW";
	}	
	if (DCMDEBUG)
		NSLog(@"init Pixel Data");
	// may may an ImageIconSequence in an encapsualted file. The icon is not encapsulated so don't de-encapsulate
	
	if ( dicomData.isEncapsulated && vl == 0xFFFFFFFF ) {
		self = [super initWithAttributeTag:tag  vr:theVR];
		[self deencapsulateData:dicomData];
		
	}
	else{
	
		self = [super init];	
		_vr = [theVR retain];
		characterSet = [specificCharacterSet retain];
		_tag = [tag retain];
		_valueLength = vl;
		_values =  nil;
		_framesDecoded = nil;
	
		//NSLog(@"data length: %d", [dicomData length]);
		if (dicomData) 
			_values = [[self valuesForVR:_vr length:_valueLength data:dicomData] retain];
		else
			_values = [[NSMutableArray array] retain];
		
		if (DCMDEBUG) 
			NSLog( self.description );

	}

	_compression = 0;
	_numberOfFrames = 1;
	_rows = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"Rows"]] value] intValue];
	_columns = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"Columns"]] value] intValue];
	_samplesPerPixel = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"SamplesperPixel"]] value] intValue];
	if ([_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"NumberofFrames"]])
		_numberOfFrames = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"NumberofFrames"]] value] intValue];
	_isSigned = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"PixelRepresentation"]] value] boolValue];
	transferSyntax = [ts retain];
	_isDecoded = NO;

	if (decodeData)
		[self decodeData];

	
	return self;
}

- (id)initWithAttributeTag:(DCMAttributeTag *)tag{
	return [super initWithAttributeTag:(DCMAttributeTag *)tag];
}

- (id)copyWithZone:(NSZone *)zone{
	DCMPixelDataAttribute *pixelAttr = [super copyWithZone:zone];
	return pixelAttr;
}
	

- (void)deencapsulateData:(DCMDataContainer *)dicomData
{
	while ([dicomData dataRemaining])
	{		
		int group = [dicomData nextUnsignedShort];
		int element = [dicomData nextUnsignedShort];
		
		int  vl = [dicomData nextUnsignedLong];
		DCMAttributeTag *attrTag = [[[DCMAttributeTag alloc]  initWithGroup:group element:element] autorelease];
		
		if (DCMDEBUG)
			NSLog(@"Attr tag: %@", attrTag.description );
			
		if ([ attrTag.stringValue isEqualToString:[(NSDictionary *)[DCMTagForNameDictionary sharedTagForNameDictionary] objectForKey:@"Item"]])
		{
			[_values addObject:[dicomData nextDataWithLength:vl]];
			
			if (DCMDEBUG)
				NSLog(@"add Frame %d with length: %d", [_values count],  vl);
		}
		else if ([[attrTag stringValue]  isEqualToString:[(NSDictionary *)[DCMTagForNameDictionary sharedTagForNameDictionary] objectForKey:@"SequenceDelimitationItem"]])  
				break;
		else
		{
			[dicomData nextDataWithLength:vl];	
		}
	}
	
}

- (void)addFrame:(NSMutableData *)data{
	
	[_values addObject:data];
}

- (void)replaceFrameAtIndex:(int)index withFrame:(NSMutableData *)data{
	[_values replaceObjectAtIndex:index withObject:data];
}

- (void)writeBaseToData:(DCMDataContainer *)dcmData transferSyntax:(DCMTransferSyntax *)ts{
	//base class cannot convert encapsulted syntaxes yet.
	NSException *exception;
	//NS_DURING
	if (DCMDEBUG)
		NSLog(@"Write Pixel Data %@", transferSyntax.description );

	if ( ts.isEncapsulated ) {		
		[dcmData addUnsignedShort:[self group]];
		[dcmData addUnsignedShort:[self element]];
		if (DCMDEBUG)
			NSLog(@"Write Sequence Base Length:%d", 0xFFFFFFFF);
		if ( ts.isExplicit ) {
			[dcmData addString:_vr];
			[dcmData  addUnsignedShort:0];		// reserved bytes
			[dcmData  addUnsignedLong:(0xFFFFFFFF)];
		}
		else {			
			[dcmData  addUnsignedLong:(0xFFFFFFFF)];
		}
	}
	//can do unencapsualated Syntaxes
	else if ( !ts.isEncapsulated )
		[super writeBaseToData:dcmData transferSyntax:ts];
		
	else {
		exception = [NSException exceptionWithName:@"DCMTransferSyntaxConversionError" reason:[NSString stringWithFormat:@"Cannot convert %@ to %@", transferSyntax.name, ts.name] userInfo:nil];
		[exception raise];
	}

}

- (BOOL)writeToDataContainer:(DCMDataContainer *)container withTransferSyntax:(DCMTransferSyntax *)ts {
	// valueLength should be 0xFFFFFFFF from constructor
	BOOL status = NO;
	if (DCMDEBUG) 
		NSLog(@"Write PixelData with TS:%@  vr: %@ encapsulated: %d", ts.description, _vr, ts.isEncapsulated );
	//NS_DURING
	if ( ts.isEncapsulated && [transferSyntax isEqualToTransferSyntax:ts]) {
		[self writeBaseToData:container transferSyntax:ts];
		for ( id object in _values ) {
			if (DCMDEBUG)
				NSLog(@"Write Item with length:%d", [(NSData *)object length]);
			[container addUnsignedShort:(0xfffe)];		// Item
			[container addUnsignedShort:(0xe000)];
			[container addUnsignedLong:[(NSData *)object length]];		
			
			[container addData:object];
			/*
			[container addUnsignedShort:(0xfffe)];		// Item Delimiter
			[container addUnsignedShort:(0xe00d)];
			[container addUnsignedLong:(0)];
			// dummy length
			*/
			
		}
		if (DCMDEBUG)
			NSLog(@"Write end sequence");
		[container addUnsignedShort:(0xfffe)];	// Sequence Delimiter
		[container addUnsignedShort:(0xe0dd)];
		[container addUnsignedLong:(0)];		// dummy length
	
		status = YES;
	}
	else {
		status = [super  writeToDataContainer:container withTransferSyntax:ts];
	} 
	/*
	NS_HANDLER
		status = NO;
	NS_ENDHANDLER
	*/
		return status;
}

- (NSString *)description{
	return  [NSString stringWithFormat:@"%@\t %@\t vl:%d\t vm:%d", _tag.description, _vr, self.valueLength, self.valueMultiplicity];
}

- (BOOL)convertToTransferSyntax:(DCMTransferSyntax *)ts quality:(int)quality{
	BOOL status = NO;
	NS_DURING
	if (DCMDEBUG)
		NSLog(@"Convert Syntax %@ to %@", transferSyntax.description, ts.description );
		//already there do nothing
	if ([transferSyntax isEqualToTransferSyntax:ts])  {
		status = YES;
		goto finishedConversion;
		//return YES;
	}

		
		//syntax is unencapsulated little Endian Explicit or Implicit for both. do nothing
	if ([[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax] isEqualToTransferSyntax:ts] && [[DCMTransferSyntax ImplicitVRLittleEndianTransferSyntax] isEqualToTransferSyntax:transferSyntax]) {
		status =  YES;
		goto finishedConversion;
	}
	if ([[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax] isEqualToTransferSyntax:transferSyntax] && [[DCMTransferSyntax ImplicitVRLittleEndianTransferSyntax] isEqualToTransferSyntax:ts]) {
		status = YES;
		goto finishedConversion;
		//return YES;
	}
	
	// we need to decode pixel data
	[self decodeData];
	
	// may need to change PixelRepresentation to 1 if it was compressed and has a intercept
	if ([[_dcmObject attributeValueWithName:@"RescaleIntercept" ] intValue] < 0) {
		//NSLog(@"Set Pixel Representation to 1");
		[_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithBool:YES]] forName:@"PixelRepresentation"];
	}
		
		
	//unencapsulated syntaxes
	if ([[DCMTransferSyntax ExplicitVRBigEndianTransferSyntax] isEqualToTransferSyntax:ts]) {
		//[_dcmObject removePlanarAndRescaleAttributes];
	
		self.transferSyntax = ts;
		status = YES;
		goto finishedConversion;
		//return YES;
	}
	if ([[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax] isEqualToTransferSyntax:ts]) {
		if (_pixelDepth > 8)
			[self convertHostToLittleEndian];
		//[_dcmObject removePlanarAndRescaleAttributes];
		self.transferSyntax = ts;
		status = YES;
		goto finishedConversion;
		//return YES;
	}
	if ([[DCMTransferSyntax ImplicitVRLittleEndianTransferSyntax] isEqualToTransferSyntax:ts]) {
		if (_pixelDepth > 8)
			[self convertHostToLittleEndian];
		//[_dcmObject removePlanarAndRescaleAttributes];
		self.transferSyntax = ts;
		status = YES;
		goto finishedConversion;
		//return YES;
	}
	
	//jpeg2000
	if ([[DCMTransferSyntax JPEG2000LosslessTransferSyntax] isEqualToTransferSyntax:ts] || [[DCMTransferSyntax JPEG2000LossyTransferSyntax] isEqualToTransferSyntax:ts] )
	{
		if( JasperInitialized == NO)
		{
			JasperInitialized = YES;
			jas_init();
		}
			
		NSMutableArray *array = [NSMutableArray array];
		for ( NSMutableData *data in _values ) {
			NSMutableData *newData = [self encodeJPEG2000:data quality:quality];
			[array addObject:newData];
		}
		for ( int i = 0; i< [array count]; i++ ) {
			[_values replaceObjectAtIndex:i withObject:[array objectAtIndex:i]];
		}
		
		if 	( [[DCMTransferSyntax JPEG2000LossyTransferSyntax] isEqualToTransferSyntax:ts] )
			[self setLossyImageCompressionRatio:[_values objectAtIndex:0]];
			
		//[_dcmObject removePlanarAndRescaleAttributes];
		[self createOffsetTable];
		self.transferSyntax = ts;
		if (DCMDEBUG)
			NSLog(@"Converted to Syntax %@", transferSyntax.description );
		status = YES;
		goto finishedConversion;
		//return YES;
	}
	
		//jpeg
	if ([[DCMTransferSyntax JPEGBaselineTransferSyntax] isEqualToTransferSyntax:ts] || [[DCMTransferSyntax JPEGExtendedTransferSyntax] isEqualToTransferSyntax:ts] || [[DCMTransferSyntax JPEGLosslessTransferSyntax] isEqualToTransferSyntax:ts] ) {
		
		NSMutableArray *values = [NSMutableArray arrayWithArray:_values];
		[_values removeAllObjects];
		//NSMutableArray *array = [NSMutableArray array];
		//[_dcmObject removePlanarAndRescaleAttributes];
		float q = 1.0;
		
		if (quality == DCMLosslessQuality)
			q = 100;
		else if (quality == DCMHighQuality)
			q = 90;
		else if (quality == DCMMediumQuality)
			q = 80;
		else if (quality == DCMLowQuality)
			q = 70;
		
		_min = 0;
		_max = 0;
		for ( NSMutableData *data in values )
		{
			NSMutableData *newData;
			if (_pixelDepth <= 8) 
				newData = [self compressJPEG8:data  compressionSyntax:ts   quality:q];
			//else if (_pixelDepth <= 12) 
			else if (_pixelDepth <= 16) 				
				newData = [self compressJPEG12:data  compressionSyntax:ts   quality:q];
			else	{	
				newData = [self compressJPEG12:data  compressionSyntax:ts   quality:q];

			}
			[self addFrame:newData];

		}
		
		/*
		for (i = 0; i< [array count]; i++) {
			[_values replaceObjectAtIndex:i withObject:[array objectAtIndex:i]];
		}
		*/	
		if 	( [[DCMTransferSyntax JPEGBaselineTransferSyntax] isEqualToTransferSyntax:ts] || [[DCMTransferSyntax JPEGExtendedTransferSyntax] isEqualToTransferSyntax:ts])
			[self setLossyImageCompressionRatio:[_values objectAtIndex:0]];
		[self createOffsetTable];
		self.transferSyntax = ts;

		status = YES;
		//goto finishedConversion;
		//return YES;
	}
	finishedConversion:
	status = status;
	NS_HANDLER
		status = NO;
	NS_ENDHANDLER
	if (DCMDEBUG)
		NSLog(@"Converted to Syntax %@ status:%d", transferSyntax.description, status);
	return status;
}

//Pixel Decoding
- (NSData *)convertDataFromLittleEndianToHost:(NSMutableData *)data{

	void *ptr = malloc([data length]);	// Much faster than using the mutableBytes function
	if( ptr)
	{
		memcpy( ptr, [data bytes], [data length]);
		
		if (NSHostByteOrder() == NS_BigEndian){
			if (_pixelDepth <= 16 && _pixelDepth > 8) {		
				//NSLog(@"Swap shorts");
				
				#if __ppc__
				if ( DCMHasAltiVec()) { 
					 SwapShorts( (vector unsigned short *) ptr, [data length]/2); 
				}
				else
				#endif
				{	
					
					int i = 0;
					unsigned short *shortsToSwap = (unsigned short *) ptr;
					//signed short *signedShort = ptr;
					int length = [data length]/2;
					for (i = 0; i < length; i++) {
						shortsToSwap[i] = NSSwapShort(shortsToSwap[i]);
					}
				}
			}
			else if (_pixelDepth > 16) {
				
				#if __ppc__
				if ( DCMHasAltiVec()) { 
					 SwapLongs( (vector unsigned int *) ptr, [data length]/4);			 
				}
				else
				#endif
				{		
					int i = 0;
					unsigned long *longsToSwap = (unsigned long *) ptr;
					//signed short *signedShort = ptr;
					int length = [data length]/4;
					for (i = 0; i < length; i++) {
						longsToSwap[i] = NSSwapLong(longsToSwap[i]);
					}
				}
			}
		}
		
		[data replaceBytesInRange:NSMakeRange(0, [data length]) withBytes: ptr];
		
		free( ptr);
	}
	return data;
}
//  Big Endian to host will need Intel Vectorizing rather than Altivec
- (NSData *)convertDataFromBigEndianToHost:(NSMutableData *)data{
	if (NSHostByteOrder() == NS_LittleEndian){
		if (_pixelDepth <= 16 && _pixelDepth > 8) {		
			int i = 0;
			unsigned short *shortsToSwap = (unsigned short *) [data mutableBytes];
			//signed short *signedShort = [data mutableBytes];
			int length = [data length]/2;
			for (i = 0; i < length; i++) {
				shortsToSwap[i] = NSSwapShort(shortsToSwap[i]);
			}
		}
		else if (_pixelDepth > 16) {
			int i = 0;
			unsigned long *longsToSwap = (unsigned long *) [data mutableBytes];
			//signed short *signedShort = [data mutableBytes];
			int length = [data length]/4;
			for (i = 0; i < length; i++) {
				longsToSwap[i] = NSSwapLong(longsToSwap[i]);
			}
		}
	}
	return data;

}
- (void)convertBigEndianToHost{
}
- (void)convertHostToBigEndian{
	if (NSHostByteOrder() == NS_LittleEndian){
		for ( NSMutableData *data in _values ) {
			if (_pixelDepth <= 16) {	
				unsigned short *shortsToSwap = (unsigned short *) [data mutableBytes];
				//signed short *signedShort = [data mutableBytes];
				unsigned int length = [data length]/2;
				for ( unsigned i = 0; i < length; i++) {
					shortsToSwap[i] = NSSwapShort(shortsToSwap[i]);
				}
			}
			else {	
				unsigned long *longsToSwap = (unsigned long *) [data mutableBytes];
				//signed short *signedShort = [data mutableBytes];
				unsigned int length = [data length]/4;
				for ( unsigned int i = 0; i < length; i++) {
					longsToSwap[i] = NSSwapLong(longsToSwap[i]);
				}
			}
		}
	}
	self.transferSyntax = [DCMTransferSyntax ExplicitVRBigEndianTransferSyntax];
}

- (void)convertLittleEndianToHost{
	if (NSHostByteOrder() == NS_BigEndian){
		for ( NSMutableData *data in _values ) {
			if (_pixelDepth <= 16) {
				#if __ppc__
				if ( DCMHasAltiVec()) { 
					 SwapShorts( (vector unsigned short *)[data mutableBytes], [data length]/2);			 
				}
				else
				#endif
				{		
					unsigned short *shortsToSwap = (unsigned short *) [data mutableBytes];
					//signed short *signedShort = [data mutableBytes];
					unsigned int length = [data length]/2;
					for ( unsigned int i = 0; i < length; i++ ) {
						shortsToSwap[i] = NSSwapShort(shortsToSwap[i]);
					}
				}
			}
			else {
				#if __ppc__
				if ( DCMHasAltiVec()) { 
					 SwapLongs( (vector unsigned int *) [data mutableBytes], [data length]/4);			 
				}
				else
				#endif
				{		
					unsigned long *longsToSwap = (unsigned long *) [data mutableBytes];
					//signed short *signedShort = [data mutableBytes];
					unsigned int length = [data length]/4;
					for ( unsigned int i = 0; i < length; i++) {
						longsToSwap[i] = NSSwapLong(longsToSwap[i]);
					}
				}
			}
		}
		self.transferSyntax = [DCMTransferSyntax ExplicitVRBigEndianTransferSyntax];
	}
	
	else
		self.transferSyntax = [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax];
}

- (void)convertHostToLittleEndian{
	if (NSHostByteOrder() == NS_BigEndian){
		for ( NSMutableData *data in _values ) {
			if (_pixelDepth <= 16) {
				#if __ppc__
				if ( DCMHasAltiVec()) 
					 SwapShorts( (vector unsigned short *) [data mutableBytes], [data length]/2);
				else
				#endif
				{
					unsigned short *shortsToSwap = (unsigned short *) [data mutableBytes];
					unsigned int length = [data length]/2;
					while (length--) {
						*shortsToSwap = NSSwapShort(*shortsToSwap);
						shortsToSwap++;
					}
				}
			}
			else {
				#if __ppc__
				if ( DCMHasAltiVec()) { 
					 SwapLongs( (vector unsigned int *) [data mutableBytes], [data length]/4);			 
				}
				else
				#endif
				{		
					unsigned long *longsToSwap = (unsigned long *) [data mutableBytes];
					//signed short *signedShort = [data mutableBytes];
					unsigned int length = [data length]/4;
					for ( unsigned int i = 0; i < length; i++ ) {
						longsToSwap[i] = NSSwapLong(longsToSwap[i]);
					}
				}
			}
		}
	}
	self.transferSyntax = [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax];
}

- (NSData *)convertJPEG8ToHost:(NSData *)jpegData{ 
	/*
	NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc] initWithData:jpegData];
	if ([imageRep isPlanar])
		NSLog(@"isPlanar: %d", [imageRep numberOfPlanes]);
	else
		NSLog(@"meshed");
	int length = [imageRep pixelsHigh] * [imageRep pixelsWide] * [imageRep samplesPerPixel];
	return [NSMutableData dataWithBytes:[imageRep bitmapData] length:length];
	*/
	return [self convertJPEG8LosslessToHost:jpegData];
}

- (NSData *)convertJPEG2000ToHost:(NSData *)jpegData
{
	int					 fmtid;
	unsigned long		i,  theLength,  x, y, decompressedLength;
	unsigned char		*theCompressedP;
	NSMutableData				*pixelData;
	
	jas_image_t *jasImage;
	jas_matrix_t *pixels[4];
	char *fmtname;
	
	theCompressedP = (unsigned char*)[jpegData bytes];
	theLength = [jpegData length];
	
	jas_stream_t *jasStream = jas_stream_memopen((char *)theCompressedP, theLength);
		
	if ((fmtid = jas_image_getfmt(jasStream)) < 0)
	{
		//RETURN( -32);
		NSLog(@"JPEG2000 stream failure");
		return nil;
	}
		// Decode the image. 
	if (!(jasImage = jas_image_decode(jasStream, fmtid, 0)))
	{
		//RETURN( -35);
		NSLog(@"JPEG2000 decode failed");
		return nil;
	}
	
	// Close the image file. 
	jas_stream_close(jasStream);
	int numcmpts = jas_image_numcmpts(jasImage);
	int width = jas_image_cmptwidth(jasImage, 0);
	int height = jas_image_cmptheight(jasImage, 0);
	int depth = jas_image_cmptprec(jasImage, 0);
	//int j;
	//int k = 0;
	fmtname = jas_image_fmttostr(fmtid);
	
	int bitDepth = 0;
	if (depth == 8)
		bitDepth = 1;
	else if (depth <= 16)
		bitDepth = 2;
	else if (depth > 16)
		bitDepth = 4;
	
	decompressedLength =  width * height * bitDepth * numcmpts;
	unsigned char *newPixelData = (unsigned char*) malloc(decompressedLength);
	
	if( UseOpenJpeg)
	{
		dcm_read_JPEG2000_file( newPixelData, (char*) theCompressedP, theLength);
	}
	else
	{
		for (i=0; i < numcmpts; i++)
			pixels[ i] = jas_matrix_create( height, width);
		
		if( numcmpts == 1)
		{
			if (depth > 8)
			{
				jas_image_readcmpt(jasImage, 0, 0, 0, width, height, pixels[0]);
				
				unsigned short *px = (unsigned short*) newPixelData;
				
				int_fast32_t	*ptr = &(pixels[0])->rows_[0][0];
				x = width*height;
				while( x-- > 0) *px++ = *ptr++;			//jas_matrix_getv(pixels[0],x);
			}
			else
			{
				jas_image_readcmpt(jasImage, 0, 0, 0, width, height, pixels[0]);
				
				char *px = (char *) newPixelData;
				
				//ICI char * aulieu de 32
				int_fast32_t	*ptr = &(pixels[0])->rows_[0][0];
				x = width*height;
				while( x-- > 0) *px++ =	*ptr++;		//jas_matrix_getv(pixels[0],x);
			}
		}
		else
		{
			[_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:@"RGB"] forName:@"PhotometricInterpretation"];	//YUV_RCT support....
			
			for( i = 0 ; i < numcmpts; i++)
				jas_image_readcmpt(jasImage, i, 0, 0, width, height, pixels[ i]);
			
			char *px = (char*) newPixelData;
			
			int_fast32_t	*ptr1 = &(pixels[0])->rows_[0][0];
			int_fast32_t	*ptr2 = &(pixels[1])->rows_[0][0];
			int_fast32_t	*ptr3 = &(pixels[2])->rows_[0][0];
			
			x = width*height;
			while( x-- > 0)
			{
				*px++ =	*ptr1++;
				*px++ =	*ptr2++;
				*px++ =	*ptr3++;		//jas_matrix_getv(pixels[0],x);
			}
		}
		
		for (i=0; i < numcmpts; i++)
			jas_matrix_destroy( pixels[ i]);
	}
	
	jas_image_destroy(jasImage);
//	jas_image_clearfmts();
	
	pixelData = [NSMutableData dataWithBytes:newPixelData length:decompressedLength ];
	free( newPixelData);
	
	return pixelData;
}

- (NSData *)convertRLEToHost:(NSData *)rleData{
	/*
		RLE header is 64 bytes long as a sequence of 16  unsigned longs.
		First elements is number of segments.  The next are length of the segments.
	*/
	unsigned int offsetTable[16];
	[rleData getBytes:offsetTable  range:NSMakeRange(0, 64)];
	int i;
	for (i = 0; i < 16; i++)
		offsetTable[i] = NSSwapLittleIntToHost(offsetTable[i]);
	int segmentCount = offsetTable[0];
	i = 0;
	/*
		if n >= 0  and < 127
			output next n+1 bytes literally
		if n < 0 and > -128
			output next byte 1-n times
		if n = -128 do nothing
	*/
	NSMutableData *decompressedData = [NSMutableData data];
	
	NS_DURING	
	int j,k, position;
	int decompressedLength = _rows * _columns;
	if (_pixelDepth > 8)
		decompressedLength *= 2;
	signed char *buffer = (signed char *)[rleData bytes];
	//buffer += 16;
	NSMutableData *data;
	//NSLog(@"segment count: %d", segmentCount);
	switch (segmentCount){
		case 1:
		{
			j = 0;
			data = [NSMutableData dataWithLength:decompressedLength];
			unsigned char *newData = (unsigned char*) [data mutableBytes];
			position = offsetTable[1];
			NSLog(@"position: %d", position);
			while ( j < decompressedLength) {
				if ((buffer[position] >= 0)) {
					int runLength = buffer[position] + 1;
					position++;
					for (k = 0; k < runLength; k++) 
						newData[j++] = buffer[position++];
				}
				else if ((buffer[position] < 0) && (buffer[position] > -128)) {
					int runLength = 1 - buffer[position];
					position++;
					for ( k = 0; k < runLength; k++)
						newData[j++] = buffer[position];
					position++;
				}
				else if (buffer[position] == -128)
					position++;
			}
			[decompressedData appendData:data];
		}
		break;
		case 2:
			data = [NSMutableData dataWithLength:decompressedLength * 2];
			for (i = 0; i< segmentCount; i++) {
				j = i;			
				unsigned char *newData = (unsigned char*) [data mutableBytes];
				position = offsetTable[i+1];
				while ( j < decompressedLength) {
					if ((buffer[position] >= 0)) {
						int runLength = buffer[position] + 1;
						position++;
						for (k = 0; k < runLength; k++) 
							newData[j+=2] = buffer[position++];
					}
					else if ((buffer[position] < 0) && (buffer[position] > -128)) {
						int runLength = 1 - buffer[position];
						position++;
						for ( k = 0; k < runLength; k++)
							newData[j+=2] = buffer[position];
						position++;
					}
					else if (buffer[position] == -128)
						position++;
				}
			}
			[decompressedData appendData:data];
			break;
		case 3:
			for (i = 0; i< segmentCount; i++) {
				j = 0;
				data = [NSMutableData dataWithLength:decompressedLength];
				unsigned char *newData = (unsigned char*) [data mutableBytes];
				position = offsetTable[i+1];
				while ( j < decompressedLength) {
					if ((buffer[position] >= 0)) {
						int runLength = buffer[position] + 1;
						position++;
						for (k = 0; k < runLength; k++) 
							newData[j++] = buffer[position++];
					}
					else if ((buffer[position] < 0) && (buffer[position] > -128)) {
						int runLength = 1 - buffer[position];
						position++;
						for ( k = 0; k < runLength; k++)
							newData[j++] = buffer[position];
						position++;
					}
					else if (buffer[position] == -128)
						position++;
				}
				[decompressedData appendData:data];
			}
		break;
		
	}
	//NSLog(@"Decompressed RLE data");
	NS_HANDLER
		NSLog(@"Error deompressing RLE");
		decompressedData = nil;
	NS_ENDHANDLER
	return decompressedData;
}

- (NSMutableData *)encodeJPEG2000:(NSMutableData *)data quality:(int)quality
{
	if( UseOpenJpeg == YES || quality != DCMLosslessQuality)	//Jasper doesn't understand the rate=0.05 parameter.... strange! Switch to openjpeg if a rate is selected
	{
		opj_cparameters_t parameters;
		opj_event_mgr_t event_mgr;
		opj_image_t *image = NULL;
		
		memset(&event_mgr, 0, sizeof(opj_event_mgr_t));
		event_mgr.error_handler = error_callback;
		event_mgr.warning_handler = warning_callback;
		event_mgr.info_handler = info_callback;

		memset(&parameters, 0, sizeof(parameters));
		opj_set_default_encoder_parameters(&parameters);
		
		switch( quality)
		{
			case DCMLosslessQuality:
				parameters.tcp_rates[0] = 0;
				parameters.tcp_numlayers = 1;
				parameters.cp_disto_alloc = 1;
			break;
			
			case DCMHighQuality:
				parameters.tcp_rates[0] = 4;
				parameters.tcp_numlayers = 1;
				parameters.cp_disto_alloc = 1;
			break;
			
			case DCMMediumQuality:
				parameters.tcp_rates[0] = 8;
				parameters.tcp_numlayers = 1;
				parameters.cp_disto_alloc = 1;
			break;
			
			case DCMLowQuality:
				parameters.tcp_rates[0] = 16;
				parameters.tcp_numlayers = 1;
				parameters.cp_disto_alloc = 1;
			break;
			
			default:
				NSLog( @"****** warning unknown compression rate -> lossless : %d", quality);
				parameters.tcp_rates[0] = 0;
				parameters.tcp_numlayers = 1;
				parameters.cp_disto_alloc = 1;
			break;
		}
		
		int image_width = _columns;
		int image_height = _rows;
		int sample_pixel = _samplesPerPixel;
		int bitsallocated = [[_dcmObject attributeValueWithName:@"BitsAllocated"] intValue];
		int bitsstored = [[_dcmObject attributeValueWithName:@"BitsStored"] intValue];
		DCMAttributeTag *signedTag = [DCMAttributeTag tagWithName:@"PixelRepresentation"];
		DCMAttribute *signedAttr = [[_dcmObject attributes] objectForKey:[signedTag stringValue]];
		BOOL sign = [[signedAttr value] boolValue];
		DCMAttributeTag *tag = [DCMAttributeTag tagWithName:@"PlanarConfiguration"];
		DCMAttribute *attr = [_dcmObject attributeForTag:(DCMAttributeTag *)tag];
		int numberofPlanes = [[attr value] intValue];
	
		image = rawtoimage( (char*) [data bytes], &parameters,  static_cast<int>( [data length]),  image_width, image_height, sample_pixel, bitsallocated, bitsstored, sign, quality, numberofPlanes);
		
		parameters.cod_format = 0; /* J2K format output */
		int codestream_length;
		opj_cio_t *cio = NULL;
		
		opj_cinfo_t* cinfo = opj_create_compress(CODEC_J2K);

		/* catch events using our callbacks and give a local context */
		opj_set_event_mgr((opj_common_ptr)cinfo, &event_mgr, stderr);

		/* setup the encoder parameters using the current image and using user parameters */
		opj_setup_encoder(cinfo, &parameters, image);

		/* open a byte stream for writing */
		/* allocate memory for all tiles */
		cio = opj_cio_open((opj_common_ptr)cinfo, NULL, 0);

		/* encode the image */
		BOOL bSuccess = opj_encode(cinfo, cio, image, NULL);
		if (!bSuccess) {
		  opj_cio_close(cio);
		  fprintf(stderr, "failed to encode image\n");
		  return false;
		}
		codestream_length = cio_tell(cio);
		
		NSMutableData *jpeg2000Data = [NSMutableData dataWithBytes: cio->buffer length: codestream_length];
		
		 /* close and free the byte stream */
		opj_cio_close(cio);
		
		/* free remaining compression structures */
		opj_destroy_compress(cinfo);
		
		opj_image_destroy(image);
		
		char zero = 0;
		if ([jpeg2000Data length] % 2) 
			[jpeg2000Data appendBytes:&zero length:1];
		
		return jpeg2000Data;
	}
	else
	{
		NSMutableData *jpeg2000Data;

		jas_image_t *image;
		jas_image_cmptparm_t cmptparms[3];
		jas_image_cmptparm_t *cmptparm;
		int i;
		int width = _columns;
		int height = _rows;
		int spp = _samplesPerPixel;
		int prec = [[_dcmObject attributeValueWithName:@"BitsAllocated"] intValue];
		DCMAttributeTag *signedTag = [DCMAttributeTag tagWithName:@"PixelRepresentation"];
		DCMAttribute *signedAttr = [[_dcmObject attributes] objectForKey:[signedTag stringValue]];
		BOOL sgnd = [[signedAttr value] boolValue];
		
		if (_isSigned)
			sgnd = _isSigned;
		
		//set up component parameters
		for (i = 0, cmptparm = cmptparms; i < spp; ++i, ++cmptparm)
		{
			cmptparm->tlx = 0;
			cmptparm->tly = 0;
			cmptparm->hstep = 1;
			cmptparm->vstep = 1;
			cmptparm->width = width;
			cmptparm->height = height;
			cmptparm->prec = prec;
			cmptparm->sgnd = sgnd;
		}
		
		//create jasper image
		if (!(image = jas_image_create(spp, cmptparms, JAS_CLRSPC_UNKNOWN)))
		{
			return nil;
		}
		
		//set colorspace
		DCMAttributeTag *tag = [DCMAttributeTag tagWithName:@"PhotometricInterpretation"];
		DCMAttribute *attr = [[_dcmObject attributes] objectForKey:[tag stringValue]];
		NSString *photometricInterpretation = [attr value];
		//int jasColorSpace = JAS_CLRSPC_UNKNOWN;
		if ([photometricInterpretation isEqualToString:@"MONOCHROME1"] || [photometricInterpretation isEqualToString:@"MONOCHROME2"])
		{
			jas_image_setclrspc(image, JAS_CLRSPC_SGRAY);
			jas_image_setcmpttype(image, 0,JAS_IMAGE_CT_COLOR(JAS_CLRSPC_CHANIND_GRAY_Y));
		}
		else if ([photometricInterpretation isEqualToString:@"RGB"] || [photometricInterpretation isEqualToString:@"ARGB"])
		{
			jas_image_setclrspc(image, JAS_CLRSPC_SRGB);
			jas_image_setcmpttype(image, 0,
			  JAS_IMAGE_CT_COLOR(JAS_CLRSPC_CHANIND_RGB_R));
			jas_image_setcmpttype(image, 1,
			  JAS_IMAGE_CT_COLOR(JAS_CLRSPC_CHANIND_RGB_G));
			jas_image_setcmpttype(image, 2,
			  JAS_IMAGE_CT_COLOR(JAS_CLRSPC_CHANIND_RGB_B));
		}
		else if ([photometricInterpretation isEqualToString:@"YBR_FULL_422"] || [photometricInterpretation isEqualToString:@"YBR_PARTIAL_422"] || [photometricInterpretation isEqualToString:@"YBR_FULL"]) {
			jas_image_setclrspc(image, JAS_CLRSPC_FAM_YCBCR);
			jas_image_setcmpttype(image, 0,
			  JAS_IMAGE_CT_COLOR(JAS_CLRSPC_CHANIND_YCBCR_Y));
			jas_image_setcmpttype(image, 1,
			  JAS_IMAGE_CT_COLOR(JAS_CLRSPC_CHANIND_YCBCR_CB));
			jas_image_setcmpttype(image, 2,
			  JAS_IMAGE_CT_COLOR(JAS_CLRSPC_CHANIND_YCBCR_CR));
			
		}
			/*
		if ([photometricInterpretation isEqualToString:@"CMYK"])
			jasColorSpace = JCS_CMYK;
			*/
			
		//component data
		int cmptno;	
		int x,y;
		jas_matrix_t *jasData[3];
		//int_fast64_t v;
		long long v;
		jasData[0] = 0;
		jasData[1] = 0;
		jasData[2] = 0;	
		for (cmptno = 0; cmptno < spp; ++cmptno)
		{
			if (!(jasData[cmptno] = jas_matrix_create( 1, width)))
			{
				return nil;
			}
		}
		
		unsigned char *dataPointer = (unsigned char*) [data bytes];
		
		for (y = 0; y < height; ++y)
		{
			for (x = 0; x < width; ++x)
			{
				for (cmptno = 0; cmptno < spp; ++cmptno)
				{
					if (_pixelDepth <= 8)
					{
						unsigned char s;
						s = *(unsigned char*) dataPointer;
						dataPointer++;
						v = s;
					}
					else if (sgnd)
					{
						signed short s;
						s = *(signed short*) dataPointer;
						dataPointer+=2;
						v = s;

					}
					else
					{
						unsigned short s;
						s = *(unsigned short*) dataPointer;
						dataPointer+=2;
						v = s;
					}
					jas_matrix_setv(jasData[cmptno], x, v);
				} //cmpt
			}	// x
			
			for (cmptno = 0; cmptno < spp; ++cmptno)
			{
				if (jas_image_writecmpt(image, cmptno, 0, y, width, 1, jasData[cmptno]))
				{
					NSLog( @"err");
				}
			} // for
		}  // y
		//done  reading data	
		
		char *optstr = nil;
		
		long theLength = [data length];
		unsigned char *outBuffer = (unsigned char *) malloc( theLength);
		jas_stream_t *outS = jas_stream_memopen((char *)outBuffer, theLength);
		jpc_encode(image, outS , optstr);
		jas_stream_flush( outS);
		long compressedLength = jas_stream_tell(outS);
		jas_stream_close( outS);
		
		jpeg2000Data = [NSMutableData dataWithBytesNoCopy: outBuffer length: compressedLength freeWhenDone: YES];
		
		for (cmptno = 0; cmptno < spp; ++cmptno)
		{
			if (jasData[cmptno])
				jas_matrix_destroy(jasData[cmptno]);
		}
		
		jas_image_destroy(image);
	//	jas_image_clearfmts();
		
		char zero = 0;
		if ([jpeg2000Data length] % 2) 
			[jpeg2000Data appendBytes:&zero length:1];
		
		return jpeg2000Data;
	}
	
	return nil;
}

- (void)decodeData
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	if (!_framesCreated)
		[self createFrames];
	int i;
	if (!_isDecoded)
	{
		for (i = 0; i < [_values count] ;i++)
		{
			[self replaceFrameAtIndex:i withFrame:[self decodeFrameAtIndex:i]];
		}
	}
	self.transferSyntax = [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax];
	
	_isDecoded = YES;
	NSString *colorspace = [_dcmObject attributeValueWithName:@"PhotometricInterpretation"];
	if ([colorspace hasPrefix:@"YBR"] || [colorspace hasPrefix:@"PALETTE"])
	{
		//remove Palette stuff
		NSMutableDictionary *attributes = [_dcmObject attributes];
		NSMutableArray *keysToRemove = [NSMutableArray array];
		for ( NSString *key in attributes ) {
			DCMAttribute *attr = [attributes objectForKey:key];
			if ([(DCMAttributeTag *)[attr attrTag] group] == 0x0028 && ([(DCMAttributeTag *)[attr attrTag] element] > 0x1100 && [(DCMAttributeTag *)[attr attrTag] element] <= 0x1223))
				[keysToRemove addObject:key];
			}
		[attributes removeObjectsForKeys:keysToRemove];
		[_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:@"RGB"] forName:@"PhotometricInterpretation"];
	}
	[pool release];
}



- (void)decodeRescale{
/*
	NSEnumerator *enumerator = [_values objectEnumerator];
	NSMutableData *data;
	while (data = [enumerator nextObject]) {
		[self decodeRescaleScalar:data];
	}	
*/
}

- (void)encodeRescale:(NSMutableData *)data WithRescaleIntercept:(int)offset{
	int length = [data length];
	int halfLength = length/2;
	[_dcmObject  setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithFloat:1.0]] forName:@"RescaleSlope"];
	[_dcmObject  setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithFloat:offset]] forName:@"RescaleIntercept"];
	int i;
	signed short *pixelData = (signed short *)[data bytes]; 
	for (i= 0; i<halfLength; i++) {
		pixelData[i] =  (pixelData[i]  - offset); 
		
		if (DCMDEBUG && !( i % 2500))
			NSLog(@"rescaled %d", pixelData[i]);
		
	}
}

- (void)encodeRescale:(NSMutableData *)data WithPixelDepth:(int)pixelDepth{

	[self encodeRescaleScalar:data withPixelDepth:pixelDepth];

}

#if __ppc__
- (void)decodeRescaleAltivec:(NSMutableData *)data{
	union vectorShort rescaleInterceptV ;
    union  vectorFloat rescaleSlopeV;
   // NSMutableData *tempData;
    short rescaleIntercept;
    float rescaleSlope;
    vector unsigned short eight = (vector unsigned short)(8);
    vector short *vPointer = (vector short *)[data mutableBytes];
	signed short *pointer =  (signed short *)[data mutableBytes]; 
    int length = [data length];
    int i = 0;
    int j = 0;
	
	if ([_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleIntercept" ]] != nil)
            rescaleIntercept = ([[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleIntercept" ]] value] intValue]);
	else 
            rescaleIntercept = 0.0;
            
    //rescale Slope
	if ([_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleSlope" ]] != nil) 
            rescaleSlope = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleSlope" ]] value] floatValue];
        
	else 
            rescaleSlope = 1.0;
		
	if ((rescaleIntercept != 0) || (rescaleSlope != 1)) {		
	   
		//Swap non G4 acceptable values. Then do rest with Altivec
	   int halfLength = length/2;
	   int vectorLength = length/16;
	   int nonVectorLength = (int)fmod(length,8);
		*pointer =+ (length - nonVectorLength);
		
		//align
		for (i= 0;  i < vectorLength; i++)            
			*vPointer++ = vec_rl(*vPointer, eight);
			//vPointer[i] = vec_rl(vPointer[i], eight);
		
		for (j = 0; j < 8; j++)
			rescaleInterceptV.scalar[j] = rescaleIntercept;                       
		
		for (j = 0; j < 4; j++)
			 rescaleSlopeV.scalar[j] = rescaleSlope;
			 
			 
		//slope is one can vecadd
		if ((rescaleIntercept != 0) && (rescaleSlope == 1)) {
			
			short *pixelData = (short *)[data mutableBytes];
			vPointer = (vector short *)[data mutableBytes];
			
			for (i = length - nonVectorLength ; i< length; i++)
				pixelData[i] =  pixelData[i] + rescaleIntercept; 
					
			for (i= 0; i<vectorLength; i++)   
				*vPointer++ = vec_add(*vPointer, rescaleInterceptV.shortVec);
		}  
		//can't vec multiple and add      
		else if ((rescaleIntercept != 0) && (rescaleSlope != 1)) {
			short *pixelData = (short *)[data bytes]; 
			//no vector for shorts and floats
			for (i= 0; i<halfLength; i++) 
				*pixelData++ =  *pixelData * rescaleSlope + rescaleIntercept;  
		}    
	}
}
- (void)encodeRescaleAltivec:(NSMutableData *)data withPixelDepth:(int)pixelDepth;{
	short rescaleIntercept = 0;
    float rescaleSlope = 1.0;
	int length = [data length];
	int halfLength = length/2;
	if ([_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleIntercept" ]] != nil)
		rescaleIntercept = ([[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleIntercept" ]] value] intValue]);
	else {
		switch (_pixelDepth) {
			case 8:
				rescaleIntercept = -127;
				break;
			case 9:
				rescaleIntercept = -255;
				break;
			case 10:
				rescaleIntercept = -511;
				break;
			case 11:
				rescaleIntercept = -1023;
				break;
			case 12:
				rescaleIntercept = -2047;
				break;
			case 13:
				rescaleIntercept = -4095;
				break;
			case 14:
				rescaleIntercept = -8191;
				break;
			case 15:
				rescaleIntercept = -16383;
				break;
			case 16:
				rescaleIntercept = -32767;
				break;
		}	
		DCMAttributeTag *tag = [DCMAttributeTag tagWithName:@"RescaleIntercept" ];
		DCMAttribute *attr = [DCMAttribute attributeWithAttributeTag:tag  vr:[tag vr]  values:[NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%f", rescaleIntercept]]];
		[_dcmObject setAttribute:attr];
	}
            
    //rescale Slope
	if ([_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleSlope" ]] != nil) 
		rescaleSlope = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleSlope" ]] value] floatValue];
        
	else  {
		rescaleSlope = 1.0;
		DCMAttributeTag *tag = [DCMAttributeTag tagWithName:@"RescaleSlope" ];
		DCMAttribute *attr = [DCMAttribute attributeWithAttributeTag:tag  vr:[tag vr]  values:[NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%f", rescaleSlope]]];
		[_dcmObject setAttribute:attr];
	}
	
	union vectorShort rescaleInterceptV ;
    union  vectorFloat rescaleSlopeV;
   // NSMutableData *tempData;

    vector unsigned short eight = (vector unsigned short)(8);
    vector short *vPointer = (vector short *)[data mutableBytes];
	signed short *pointer =  (signed short *)[data mutableBytes]; 

    int i = 0;
    int j = 0;

	  //rescale Intercept
       
            //Swap non G4 acceptable values. Then do rest with Altivec


       int vectorLength = length/16;
       int nonVectorLength = (int)fmod(length,8);

        *pointer =+ (length - nonVectorLength);
        
        for (i= nonVectorLength;  i < vectorLength; i++)            
            *vPointer++ = vec_rl(*vPointer, eight);
        
        for (j = 0; j < 8; j++)
			rescaleInterceptV.scalar[j] = -rescaleIntercept;                       
		
		for (j = 0; j < 4; j++)
			 rescaleSlopeV.scalar[j] = rescaleSlope;

        if ((rescaleIntercept != 0) && (rescaleSlope == 1)) {
            
            short *pixelData = (short *)[data mutableBytes];
            vPointer = (vector short *)[data mutableBytes];
            for (i = 0; i< nonVectorLength; i++)
				*pixelData++ =  *pixelData - rescaleIntercept; 
                    
            for (i= nonVectorLength; i<vectorLength; i++)   
                *vPointer++ = vec_add(*vPointer, rescaleInterceptV.shortVec);
        }        
        else if ((rescaleIntercept != 0) && (rescaleSlope != 1)) {
            short *pixelData = (short *)[data bytes]; 
			//n0 vector for shorts and floats
            for (i= 0; i<halfLength; i++) 
                *pixelData++ =  *pixelData / rescaleSlope - rescaleIntercept;  
        }

    
}

#endif

- (void)decodeRescaleScalar:(NSMutableData *)data{
    short rescaleIntercept;
    float rescaleSlope;
	int length = [data length];
	 int halfLength = length/2;
	if ([_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleIntercept" ]] != nil)
            rescaleIntercept = ([[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleIntercept" ]] value] intValue]);
	else 
            rescaleIntercept = 0.0;
            
    //rescale Slope
	if ([_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleSlope" ]] != nil) 
            rescaleSlope = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleSlope" ]] value] floatValue];
        
	else 
            rescaleSlope = 1.0;
			
	if ((rescaleIntercept != 0) || (rescaleSlope != 1)) {
		
		int i;
		short *pixelData = (short *)[data bytes]; 
		short value;
		for (i= 0; i<halfLength; i++) {
			value = *pixelData * rescaleSlope + rescaleIntercept;
			if (value < 0)
				_isSigned = YES;
			*pixelData++ =  value; 
		}
	}
}

- (void)encodeRescaleScalar:(NSMutableData *)data withPixelDepth:(int)pixelDepth;{

	short rescaleIntercept = 0;
    float rescaleSlope = 1.0;
	int length = [data length];
	int halfLength = length/2;
	if ([_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleIntercept" ]] != nil &&
			[[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleIntercept" ]] value] intValue] < 0)
		rescaleIntercept = ([[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleIntercept" ]] value] intValue]);
	else {
		switch (_pixelDepth) {
			case 8:
				rescaleIntercept = -127;
				break;
			case 9:
				rescaleIntercept = -255;
				break;
			case 10:
				rescaleIntercept = -511;
				break;
			case 11:
				rescaleIntercept = -1023;
				break;
			case 12:
				rescaleIntercept = -2047;
				break;
			case 13:
				//rescaleIntercept = 4095;
				//break;
			case 14:
				//rescaleIntercept = 8191;
				//break;
			case 15:
				//rescaleIntercept = 16383;
				//break;
			case 16:
				//rescaleIntercept = 32767;
				[self findMinAndMax:data];
				if (_min < 0)
					rescaleIntercept = _min;
				break;
			default: rescaleIntercept = -2047;
		}	

	[_dcmObject  setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithInt:rescaleIntercept]] forName:@"RescaleIntercept"];
	}
            
    //rescale Slope
	if ([_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleSlope" ]] != nil) 
		rescaleSlope = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"RescaleSlope" ]] value] floatValue];
        
	else  {
	
		if (rescaleIntercept > -2048)
			rescaleSlope = 1.0;
		else if (_max - _min > pow(2, pixelDepth))
			rescaleSlope = (_max - _min) / pow(2, pixelDepth);
				
		rescaleSlope = 1.0;	
		[_dcmObject  setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithFloat:rescaleSlope]] forName:@"RescaleSlope"];
	}
		
	if (DCMDEBUG) {
		NSLog(@"rescales Intercept: %d slope: %f", rescaleIntercept, rescaleSlope);
		NSLog(@"max: %d min %d", _max, _min);
	}
	if ((rescaleIntercept != 0) || (rescaleSlope != 1)) {
		int i;
		signed short *pixelData = (signed short *)[data bytes]; 
		for (i= 0; i<halfLength; i++)
		{
			pixelData[i] =  (pixelData[i]  - rescaleIntercept) / rescaleSlope;
		}
	}
}


-(void)createOffsetTable{
	/*
		offset should be item tag 4 bytes length 4 bytes last item length
	*/
	if (DCMDEBUG)
		NSLog(@"create Offset table");
	NSMutableData *offsetTable = [NSMutableData data];
	unsigned long offset = 0;
	[offsetTable appendBytes:&offset length:4];
	int i;
	int count = [_values count];
	for (i = 1; i < count; i++) {
		offset += NSSwapHostLongToLittle([(NSData *)[_values objectAtIndex:i -1] length] + 8);
		[offsetTable appendBytes:&offset length:4];
	}
	[_values insertObject:offsetTable atIndex:0];
}

- (NSData *)interleavePlanesInData:(NSData *)planarData{
	DCMAttributeTag *tag = [DCMAttributeTag tagWithName:@"PlanarConfiguration"];
	DCMAttribute *attr = [_dcmObject attributeForTag:(DCMAttributeTag *)tag];
	int numberofPlanes = [[attr value] intValue];
	int i,j, k;
	int bytes = 1;
	if (_pixelDepth <= 8)
		bytes = 1;
	else if (_pixelDepth <= 16)
		bytes = 2;
	else
		bytes = 4;
	int planeLength = _rows * _columns;
	NSMutableData *interleavedData = nil;
	if (numberofPlanes > 0 && numberofPlanes <= 4) {
		interleavedData = [NSMutableData dataWithLength:[planarData length]];
		if (bytes == 1) {

			unsigned char *planarBuffer = (unsigned char *)[planarData  bytes];
			unsigned char *bitmapData = (unsigned char *)[interleavedData  mutableBytes];
			for(i=0; i< _rows; i++){

				for(j=0; j< _columns; j++){
					for (k = 0; k < _samplesPerPixel; k++)
						*bitmapData++ = planarBuffer[planeLength*k + i*_columns + j ];

				}
			}
		}
		else if (bytes == 2) {
			unsigned short *planarBuffer = (unsigned short *)[planarData  bytes];
			unsigned short *bitmapData = (unsigned short *)[interleavedData  mutableBytes];
			for(i=0; i< _rows; i++){
				for(j=0; j< _columns; j++){
					for (k = 0; k < _samplesPerPixel; k++)
						*bitmapData++ = planarBuffer[planeLength*k + i*_columns + j ];

				}
			}
		}
		else {
			unsigned long *planarBuffer = (unsigned long *)[planarData  bytes];
			unsigned long *bitmapData = (unsigned long *)[interleavedData  mutableBytes];
			for(i=0; i< _rows; i++){
				for(j=0; j< _columns; j++){
					for (k = 0; k < _samplesPerPixel; k++)
						*bitmapData++ = planarBuffer[planeLength*k + i*_columns + j ];

				}
			}
		}
	}
	//already interleaved
	else
		return planarData;
	return interleavedData;
}

- (void)interleavePlanes{
	DCMAttributeTag *tag = [DCMAttributeTag tagWithName:@"PlanarConfiguration"];
	DCMAttribute *attr = [_dcmObject attributeForTag:(DCMAttributeTag *)tag];
	int numberofPlanes = [[attr value] intValue];
	NSMutableArray *dataArray = [NSMutableArray array];
	int bytes = 1;
	if (_pixelDepth <= 8)
		bytes = 1;
	else if (_pixelDepth <= 16)
		bytes = 2;
	else
		bytes = 4;
	int planeLength = _rows * _columns;
	if (numberofPlanes > 0 && numberofPlanes <= 4) {

		for ( NSMutableData *planarData in _values ) {
			NSMutableData *interleavedData = [NSMutableData dataWithLength:[planarData length]];
			if (bytes == 1) {

				unsigned char *planarBuffer = (unsigned char *)[planarData  bytes];
				unsigned char *bitmapData = (unsigned char *)[interleavedData  mutableBytes];
				for( unsigned int i=0; i < _rows; i++ ) {
					for( unsigned int j=0; j< _columns; j++ ) {
						for ( unsigned int k = 0; k < _samplesPerPixel; k++ )
							*bitmapData++ = planarBuffer[planeLength*k + i*_columns + j ];

					}
				}
			}
			else if (bytes == 2) {
				unsigned short *planarBuffer = (unsigned short *)[planarData  bytes];
				unsigned short *bitmapData = (unsigned short *)[interleavedData  mutableBytes];
				for ( unsigned int i=0; i< _rows; i++ ) {
					for ( unsigned int j=0; j< _columns; j++ ) {
						for ( unsigned int k = 0; k < _samplesPerPixel; k++ )
							*bitmapData++ = planarBuffer[planeLength*k + i*_columns + j ];

					}
				}
			}
			else {
				unsigned long *planarBuffer = (unsigned long *)[planarData  bytes];
				unsigned long *bitmapData = (unsigned long *)[interleavedData  mutableBytes];
				for ( unsigned int i=0; i< _rows; i++ ) {
					for ( unsigned int j=0; j< _columns; j++ ) {
						for ( unsigned int k = 0; k < _samplesPerPixel; k++ )
							*bitmapData++ = planarBuffer[planeLength*k + i*_columns + j ];

					}
				}
			}
			[dataArray addObject:interleavedData];
		}
		for ( unsigned int i = 0; i< [dataArray count]; i++)
			[_values replaceObjectAtIndex:i withObject:[dataArray objectAtIndex:i]];
	}
}

- (void)setLossyImageCompressionRatio:(NSMutableData *)data{
	int numBytes = 1;
	if (_pixelDepth > 8)
		numBytes = 2;
	float uncompressedSize = _rows * _columns * _samplesPerPixel * numBytes;
	float compression = uncompressedSize/(float)[data length];

	NSString *ratio = [NSString stringWithFormat:@"%f", compression];
	DCMAttributeTag *ratioTag = [DCMAttributeTag tagWithName:@"LossyImageCompressionRatio"];
	DCMAttribute *ratioAttr = [DCMAttribute attributeWithAttributeTag:ratioTag vr:[ratioTag vr] values:[NSMutableArray arrayWithObject:ratio]];
	
	DCMAttributeTag *compressionTag = [DCMAttributeTag tagWithName:@"LossyImageCompression"];
	DCMAttribute *compressionAttr = [DCMAttribute attributeWithAttributeTag:compressionTag vr:[compressionTag vr] values:[NSMutableArray arrayWithObject:@"01"]];
	
	[[_dcmObject attributes] setObject:ratioAttr  forKey:[ratioTag stringValue]];
	[[_dcmObject attributes] setObject:compressionAttr  forKey:[compressionTag stringValue]];
	//LossyImageCompression
}

- (void)findMinAndMax:(NSMutableData *)data{
	int i = 0;
	int length;
	DCMAttributeTag *signedTag = [DCMAttributeTag tagWithName:@"PixelRepresentation"];
	DCMAttribute *signedAttr = [[_dcmObject attributes] objectForKey:[signedTag stringValue]];
	BOOL isSigned = [[signedAttr value] boolValue];
	float max,  min;
	
	if (_pixelDepth <= 8) 
		length = [data length];
	else if (_pixelDepth <= 16)
		length = [data length]/2;
	else
		length = [data length] / 4;
		
	float *fBuffer = (float*) malloc(length * 4);
	if (_pixelDepth <= 8) {
		unsigned char *buffer = (unsigned char *)[data bytes];
		while (i < length) {
			fBuffer[i] = (float)buffer[i];
			i++;
		}
	}
	else if (_pixelDepth <= 16 && (isSigned || _isSigned)) {
		signed short  *buffer = (signed short *)[data bytes];
		while (i < length) {
			fBuffer[i] = (float)buffer[i];
			i++;
		}
	}
	else if (_pixelDepth <= 16) {
		unsigned short  *buffer = (unsigned short  *)[data bytes];
		while (i < length){
			fBuffer[i] = (float)buffer[i];
			i++;
		}
	}
//	else
//		int *buffer = (int *) [data bytes];
		
	vDSP_minv (fBuffer, 1, &min, length);
	vDSP_maxv (fBuffer, 1, &max, length);
	NSLog(@"vmax: %f vmin: %f", max, min);
	
	free(fBuffer);

	/*
	if (_pixelDepth <= 8) {
		_max = 255;
		_min = 0;
	}
	else  {
	
		if ((_min == 0) && (_max == 0)) {
			if (isSigned || _isSigned) {				
				signed short *buffer = (signed short *)[data bytes];
				signed short value;
				length = [data length]/ 2;
				_min = 32768;
				_max = -32767;
				for (i= 0; i < length; i++) {
					value = buffer[i];
					if (value < _min) {
						//NSLog(@"New min: %d old min: %d i: %d x: %d  y: %d", value, _min, i, i/256, i%256);
						_min = value;
					}
					if (value > _max)
						_max = value;
					
				}
			}
			else {
				_max = 0;
				_min = 65535;
				unsigned short *buffer = (unsigned short *)[data bytes];
				unsigned short value;
				length = [data length]/ 2;
				for (i = 0; i < length; i++) {
					value = buffer[i];
					if (value < _min)
						_min = value;
					if (value > _max)
						_max = value;
					
				}
			}
		}
	}
	*/
	if (DCMDEBUG)
		NSLog(@"min %d max %d", _min, _max);
}

- (NSData *)convertPaletteToRGB:(NSData *)data
{	
	BOOL			fSetClut = NO, fSetClut16 = NO;
	unsigned char   *clutRed = nil, *clutGreen = nil, *clutBlue = nil;
	int		clutEntryR = 0, clutEntryG = 0, clutEntryB = 0;
	unsigned short		clutDepthR, clutDepthG, clutDepthB;
	unsigned short	*shortRed = nil, *shortGreen = nil, *shortBlue = nil;
	long height = _rows;
	long width = _columns;
	long realwidth = width;
	long depth = _pixelDepth;
	int j;
	NSMutableData *rgbData = nil;
	NS_DURING
	//PhotoInterpret
	if ([[_dcmObject attributeValueWithName:@"PhotometricInterpretation"] rangeOfString:@"PALETTE"].location != NSNotFound)
	{
		BOOL found = NO, found16 = NO;
		clutRed = (unsigned char*) calloc( 65536, 1);
		clutGreen = (unsigned char*) calloc( 65536, 1);
		clutBlue = (unsigned char*) calloc( 65536, 1);
		
		// initialisation
		clutEntryR = clutEntryG = clutEntryB = 0;
		clutDepthR = clutDepthG = clutDepthB = 0;
		
		NSArray *redLUTDescriptor = [_dcmObject attributeArrayWithName:@"RedPaletteColorLookupTableDescriptor"];
		clutEntryR = (unsigned short)[[redLUTDescriptor objectAtIndex:0] intValue];
		clutDepthR = (unsigned short)[[redLUTDescriptor objectAtIndex:2] intValue];
		NSArray *greenLUTDescriptor = [_dcmObject attributeArrayWithName:@"GreenPaletteColorLookupTableDescriptor"];
		clutEntryG = (unsigned short)[[greenLUTDescriptor objectAtIndex:0] intValue];
		clutDepthG = (unsigned short)[[greenLUTDescriptor objectAtIndex:2] intValue];
		NSArray *blueLUTDescriptor = [_dcmObject attributeArrayWithName:@"BluePaletteColorLookupTableDescriptor"];
		clutEntryB = (unsigned short)[[blueLUTDescriptor objectAtIndex:0] intValue];
		clutDepthB = (unsigned short)[[blueLUTDescriptor objectAtIndex:2] intValue];
		
		if( clutEntryR > 256) NSLog(@"R-Palette > 256");
		if( clutEntryG > 256) NSLog(@"G-Palette > 256");
		if( clutEntryB > 256) NSLog(@"B-Palette > 256");
		
		//NSLog(@"%d red entries with depth: %d", clutEntryR , clutDepthR);
		//NSLog(@"%d green entries with depth: %d", clutEntryG , clutDepthG);
		//NSLog(@"%d blue entries with depth: %d", clutEntryB , clutDepthB);
		unsigned long nbVal;
		unsigned short *val;
		
		NSMutableData *segmentedRedData = [_dcmObject attributeValueWithName:@"SegmentedRedPaletteColorLookupTableData"];		
		if (segmentedRedData)	// SEGMENTED PALETTE - 16 BIT !
		{
			NSLog(@"Segmented LUT");
			if (clutDepthR == 16  && clutDepthG == 16  && clutDepthB == 16)
			{
				long			length, xx, xxindex, jj;
				
				shortRed = (unsigned short*) malloc( 65535L * sizeof( unsigned short));
				shortGreen = (unsigned short*) malloc( 65535L * sizeof( unsigned short));
				shortBlue = (unsigned short*) malloc( 65535L * sizeof( unsigned short));
				
				// extract the RED palette clut data
				val = (unsigned short *)[segmentedRedData bytes];
				if (val != NULL)
				{
					unsigned short  *ptrs =  (unsigned short*) val;
					nbVal = [segmentedRedData length] / 2;
					
					NSLog(@"red");
					
					xxindex = 0;
					for( jj = 0; jj < nbVal;jj++)
					{
						int type = NSSwapLittleShortToHost(ptrs[jj]);
						//NSLog(@"Type: %d", type);
						switch(type)
						{
							case 0:	// Discrete
								jj++;
								length = NSSwapLittleShortToHost(ptrs[jj]);
								jj++;
								for( xx = xxindex; xxindex < xx + length; xxindex++)
								{
									unsigned short pixel = NSSwapLittleShortToHost(ptrs[ jj++]);
									shortRed[ xxindex] = pixel;
									//if( xxindex < 256) NSLog(@"Type: %d  pixel:%d, swapped: %d", shortRed[ xxindex], NSSwapLittleShortToHost(shortRed[ xxindex]));
								}
								jj--;
							break;
							
							case 1:	// Linear
								jj++;
								length = NSSwapLittleShortToHost(ptrs[jj]);
								for( xx = xxindex; xxindex < xx + length; xxindex++)
								{
									unsigned short pixel = NSSwapLittleShortToHost(ptrs[ jj + 1]);
									shortRed[ xxindex] = shortRed[ xx-1] + ((pixel - shortRed[ xx-1]) * (1+xxindex - xx)) / (length);
									//if( xxindex < 256) NSLog(@"%d", shortRed[ xxindex]);
								}
								jj ++;
							break;
							
							case 2: // Indirect
								NSLog(@"indirect not supported");
								jj++;
								length = NSSwapLittleShortToHost(ptrs[jj]);

								jj += 2;
							break;
							
							default:
								NSLog(@"Error, Error, OsiriX will soon crash...");
							break;
						}
					}
					found16 = YES; 	// this is used to let us know we have to look for the other element */
					NSLog(@"%d", xxindex);
				}//endif
				
				// extract the GREEN palette clut data
				NSMutableData *segmentedGreenData = [_dcmObject attributeValueWithName:@"SegmentedGreenPaletteColorLookupTableData"];
				val = (unsigned short *)[segmentedGreenData bytes];
				if (val != NULL)
				{
					unsigned short  *ptrs =  (unsigned short*) val;
					nbVal = [segmentedGreenData length] / 2;
					
					NSLog(@"green");
					
					xxindex = 0;
					for( jj = 0; jj < nbVal; jj++)
					{
						int type = NSSwapLittleShortToHost(ptrs[jj]);
						//NSLog(@"Green Type: %d", type);
						switch(type)
						{
							case 0:	// Discrete
								jj++;
								length = NSSwapLittleShortToHost(ptrs[jj]);
								jj++;
								for( xx = xxindex; xxindex < xx + length; xxindex++)
								{
									unsigned short pixel = NSSwapLittleShortToHost(ptrs[ jj++]);
									shortGreen[ xxindex] = pixel;
									//if( xxindex < 256) NSLog(@"%d", shortGreen[ xxindex]);
								}
								jj--;
							break;
							
							case 1:	// Linear
								jj++;
								length = NSSwapLittleShortToHost(ptrs[jj]);
								for( xx = xxindex; xxindex < xx + length; xxindex++)
								{
									unsigned short pixel = NSSwapLittleShortToHost(ptrs[ jj + 1]);
									shortGreen[ xxindex] = shortGreen[ xx-1] + ((pixel - shortGreen[ xx-1]) * (1+xxindex - xx)) / (length);
								//	if( xxindex < 256) NSLog(@"%d", shortGreen[ xxindex]);
								}
								jj ++;
							break;
							
							case 2: // Indirect
								NSLog(@"indirect not supported");
								jj++;
								length = NSSwapLittleShortToHost(ptrs[jj]);

								jj += 2;
							break;
							
							default:
								NSLog(@"Error, Error, OsiriX will soon crash...");
							break;
						}
					}
					found16 = YES; 	// this is used to let us know we have to look for the other element 
					NSLog(@"%d", xxindex);
				}//endif
				
				// extract the BLUE palette clut data
				NSMutableData *segmentedBlueData = [_dcmObject attributeValueWithName:@"SegmentedBluePaletteColorLookupTableData"];
				val = (unsigned short *)[segmentedBlueData  bytes];
				if (val != NULL)
				{
					unsigned short  *ptrs =  (unsigned short*) val;
					nbVal = [segmentedBlueData length] / 2;
					
					NSLog(@"blue");
					
					xxindex = 0;
					for( jj = 0; jj < nbVal; jj++)
					{
						int type = NSSwapLittleShortToHost(ptrs[jj]);
						//NSLog(@"Blue Type: %d", type);
						switch(type)
						{
							case 0:	// Discrete
								jj++;
								length = NSSwapLittleShortToHost(ptrs[jj]);
								jj++;
								for( xx = xxindex; xxindex < xx + length; xxindex++)
								{
									unsigned short pixel = NSSwapLittleShortToHost(ptrs[ jj++]);
									shortBlue[ xxindex] = pixel;
						//			if( xxindex < 256) NSLog(@"%d", shortBlue[ xxindex]);
								}
								jj--;
							break;
							
							case 1:	// Linear
								jj++;
								length = NSSwapLittleShortToHost(ptrs[jj]);
								for( xx = xxindex; xxindex < xx + length; xxindex++)
								{
									unsigned short pixel = NSSwapLittleShortToHost(ptrs[ jj + 1]);
									shortBlue[ xxindex] = shortBlue[ xx-1] + ((pixel - shortBlue[ xx-1]) * (xxindex - xx + 1)) / (length);
									//if( xxindex < 256) NSLog(@"%d", shortBlue[ xxindex]);
								}
								jj ++;
							break;
							
							case 2: // Indirect
								NSLog(@"indirect not supported");
								jj++;
								length = NSSwapLittleShortToHost(ptrs[jj]);

								jj += 2;
							break;
							
							default:
								NSLog(@"Error, Error, OsiriX will soon crash...");
							break;
						}
					}
					found16 = YES; 	// this is used to let us know we have to look for the other element 
					NSLog(@"%d", xxindex);
				}//endif
				/*
				for( jj = 0; jj < 65535; jj++)
				{
					shortRed[jj] =shortRed[jj]>>8;
					shortGreen[jj] =shortGreen[jj]>>8;
					shortBlue[jj] =shortBlue[jj]>>8;
				}
				*/
			}  //end 16 bit
			else if (clutDepthR == 8  && clutDepthG == 8  && clutDepthB == 8)
			{
				NSLog(@"Segmented palettes for 8 bits ??");
			}
			else
			{
				NSLog(@"Dont know this kind of DICOM CLUT...");
			}
		} //end segmented
		// EXTRACT THE PALETTE data only if there is 256 entries and depth is 16 bits
		else if (clutDepthR == 16  && clutDepthG == 16  && clutDepthB == 16)
		{
			NSLog(@"16 bit PALETTE");
			NSData *redCLUT = [_dcmObject attributeValueWithName:@"RedPaletteColorLookupTableData"];
			if (redCLUT) {
				if (clutEntryR == 0) 
					clutEntryR = [redCLUT length] / 2;
				
				//NSLog(@"Red CLUT length: %d %d ", clutEntryR, lutLength);
				unsigned short  *ptrs =  (unsigned short*) [redCLUT bytes];				
				for (j = 0; j < clutEntryR; j++, ptrs++) {
					clutRed [j] = (int) (NSSwapLittleShortToHost(*ptrs)/256);
				}
				found = YES; 	// this is used to let us know we have to look for the other element 
			}//endif red
			
					// extract the GREEN palette clut data
			NSData *greenCLUT = [_dcmObject attributeValueWithName:@"GreenPaletteColorLookupTableData"];
			if (greenCLUT) {
				if (clutEntryG == 0)
					clutEntryG = [greenCLUT length] / 2;
				unsigned short  *ptrs =  (unsigned short*) [greenCLUT bytes];
				for (j = 0; j < clutEntryG; j++, ptrs++) clutGreen [j] = (int) (NSSwapLittleShortToHost(*ptrs)/256);
			}//endif green
			
			// extract the BLUE palette clut data
			NSData *blueCLUT = [_dcmObject attributeValueWithName:@"BluePaletteColorLookupTableData"];
			if (blueCLUT) {
				if (clutEntryB == 0)
					clutEntryB = [blueCLUT length] / 2;
				unsigned short  *ptrs =  (unsigned short*) [blueCLUT bytes];
				for (j = 0; j < clutEntryB; j++, ptrs++) clutBlue [j] = (int) (NSSwapLittleShortToHost(*ptrs)/256);
			} //endif blue
			
		}  //end 16 bit
		
		// if ...the palette has 256 entries and thus we extract the clut datas
	
		else if (clutDepthR == 8  && clutDepthG == 8  && clutDepthB == 8) {
			NSLog(@"Converting 8 bit LUT. Red LUT: %@", [_dcmObject attributeWithName:@"RedPaletteColorLookupTableData"].description );
			DCMAttribute *redCLUT = [_dcmObject attributeWithName:@"RedPaletteColorLookupTableData"];
			//NSData *redCLUT = [_dcmObject attributeValueWithName:@"RedPaletteColorLookupTableData"];
			if (redCLUT) {
				// in case we have an array rather than NSData
				if ([redCLUT valueMultiplicity] > 1) {
					NSArray *lut = [redCLUT values];
					for (j = 0; j < clutEntryR; j++) clutRed [j] = (int) [[lut objectAtIndex:j] intValue];
					found = YES;
				}
				else{
					unsigned char  *ptrs =  (unsigned char*) [[redCLUT value] bytes];
					for (j = 0; j < clutEntryR; j++, ptrs++) clutRed [j] = (int) (*ptrs);
						found = YES; 	// this is used to let us know we have to look for the other element 
				}
			}
			
			// extract the GREEN palette clut data
			DCMAttribute *greenCLUT = [_dcmObject attributeWithName:@"GreenPaletteColorLookupTableData"];
			//NSData *greenCLUT = [_dcmObject attributeValueWithName:@"GreenPaletteColorLookupTableData"];
			if (greenCLUT) {
				// in case we have an array rather than NSData
				if ([greenCLUT valueMultiplicity] > 1) {
					NSArray *lut = [greenCLUT values];
					for (j = 0; j < clutEntryG; j++) clutGreen [j] = (int) [[lut objectAtIndex:j] intValue];
					found = YES;
				}
				else{
					unsigned char  *ptrs =  (unsigned char*) [[greenCLUT value] bytes];
					for (j = 0; j < clutEntryG; j++, ptrs++) clutGreen [j] = (int) (*ptrs);
						found = YES; 	// this is used to let us know we have to look for the other element 
				}
			}
			
			// extract the BLUE palette clut data
			DCMAttribute *blueCLUT = [_dcmObject attributeWithName:@"BluePaletteColorLookupTableData"];
			//NSData *blueCLUT = [_dcmObject attributeValueWithName:@"BluePaletteColorLookupTableData"];
			if (blueCLUT) {
				// in case we have an array rather than NSData
				if ([blueCLUT valueMultiplicity] > 1) {
					NSArray *lut = [blueCLUT values];
					for (j = 0; j < clutEntryB; j++) clutBlue [j] = (int) [[lut objectAtIndex:j] intValue];
					found = YES;
				}
				else{
					unsigned char  *ptrs =  (unsigned char*) [[greenCLUT value] bytes];
					for (j = 0; j < clutEntryB; j++, ptrs++) clutBlue [j] = (int) (*ptrs);
						found = YES; 	// this is used to let us know we have to look for the other element 
				}

			}
			// let the rest of the routine know that it should set the clut
		}
		if (found) fSetClut = YES;
		if (found16) fSetClut16 = YES;
	
	} // endif ...extraction of the color palette
	
// This image has a palette -> Convert it to a RGB image !
	if( fSetClut)
	{
		if( clutRed != nil && clutGreen != nil && clutBlue != nil)
		{
			unsigned char   *bufPtr = (unsigned char*) [data bytes];
			unsigned short	*bufPtr16 = (unsigned short*) [data bytes];
			unsigned char   *tmpImage;
			long			totSize, pixelR, pixelG, pixelB, x, y;
			int i= 0;
			totSize = (long) ((long) height * (long) realwidth * 3L);
			//tmpImage = malloc( totSize);
			rgbData = [NSMutableData dataWithLength:totSize];
			tmpImage = (unsigned char*) [rgbData mutableBytes];
			
			//if( _pixelDepth != 8) NSLog(@"Palette with a non-8 bit image??? : %d ", _pixelDepth);
			//NSLog(@"height; %d  width %d totSize: %d, length: %d", height, realwidth, totSize, [data length]);
			switch(_pixelDepth)
			{
				case 8:
					
					for( y = 0; y < height; y++)
					{
						for( x = 0; x < width; x++)
						{
							pixelR = pixelG = pixelB = bufPtr[y*width + x];
							
							if( pixelR > clutEntryR) {	pixelR = clutEntryR-1;}
							if( pixelG > clutEntryG) {	pixelG = clutEntryG-1;}
							if( pixelB > clutEntryB) {	pixelB = clutEntryB-1;}

							tmpImage[y*width*3 + x*3 + 0] = clutRed[ pixelR];
							tmpImage[y*width*3 + x*3 + 1] = clutGreen[ pixelG];
							tmpImage[y*width*3 + x*3 + 2] = clutBlue[ pixelB];
						}
					}
				
				break;
			
				case 16:
					i = 0;
					for( y = 0; y < height; y++)
					{
						for( x = 0; x < width; x++)
						{
							pixelR = pixelG = pixelB = NSSwapBigShortToHost( bufPtr16[i]);
							tmpImage[i*3 + 0] = clutRed[ pixelR];
							tmpImage[i*3 + 1] = clutGreen[ pixelG];
							tmpImage[i*3 + 2] = clutBlue[ pixelB];
							i++;
							
						}
					}
				break;
			}
			
		}
	}
	
	if( fSetClut16){
		unsigned short	*bufPtr = (unsigned short*) [data bytes];
		unsigned short   *tmpImage;
		long			totSize, x, y, ii;

		unsigned short pixel;
		
		totSize = (long) ((long) _rows * (long) _columns * 3L * 2);
		rgbData = [NSMutableData dataWithLength:totSize];
		tmpImage = (unsigned short *)[rgbData mutableBytes];
		
		if( depth != 16) NSLog(@"Segmented Palette with a non-16 bit image???");
		
		ii = height * realwidth;
				
		for( y = 0; y < height; y++)
		{
			for( x = 0; x < width; x++)
			{
				//pixel = NSSwapLittleShortToHost(bufPtr[y*width + x]);
				pixel = (bufPtr[y*width + x]);
				tmpImage[y*width*3 + x*3 + 0] = shortRed[pixel];
				tmpImage[y*width*3 + x*3 + 1] = shortGreen[ pixel];
				tmpImage[y*width*3 + x*3 + 2] = shortBlue[ pixel];
				//if ((y*width + x) % 5000 == 0)
				//	NSLog(@"y: %d x: %d red: %d  green: %d  blue: %d", y , x, shortRed[pixel], shortGreen[ pixel],shortBlue[ pixel]);
			}
		}
		

	} //done converting Palette
NS_HANDLER
	rgbData = nil;
	NSLog(@"Exception converting Palette to RGB: %@", localException.name);
NS_ENDHANDLER
	if( clutRed != nil)
		free(clutRed);
	if ( clutGreen != nil)
		free(clutGreen);
	if (clutBlue != nil)
		free(clutBlue);
		
	if (shortRed != nil)
		free(shortRed);
	if (shortGreen != nil)	
		free(shortGreen);
	if (shortBlue != nil)
		free(shortBlue);
	//NSLog(@"end palette conversion end length: %d", [rgbData length]);
	_pixelDepth = 8;	
	return rgbData;

}

- (NSData *) convertYBrToRGB:(NSData *)ybrData kind:(NSString *)theKind isPlanar:(BOOL)isPlanar
{
  long			loop, size;
  unsigned char		*pYBR, *pRGB;
  unsigned char		*theRGB;
  int			y, y1, r;
  NSMutableData *rgbData;
  
  NSLog(@"convertYBrToRGB:%@ isPlanar:%d", theKind, isPlanar);
  // the planar configuration should be set to 0 whenever
  // YBR_FULL_422 or YBR_PARTIAL_422 is used
  if (![theKind isEqualToString:@"YBR_FULL"] && isPlanar == 1)
    return nil;
  
  // allocate room for the RGB image
  int length = ( _rows *  _columns * 3);
  rgbData = [NSMutableData dataWithLength:length];
  theRGB = (unsigned char*) [rgbData mutableBytes];
  if (theRGB == nil) return nil;
  pRGB = theRGB;
  size = (long) _rows * (long) _columns;
 // int kind = 0;
 
    int32_t R, G, B;
   uint8_t a;
   uint8_t b;
   uint8_t c;
   
  switch (isPlanar)
  {
    case 0 : // all pixels stored one after the other
      if ([theKind isEqualToString:@"YBR_FULL"])
      {
          // loop on the pixels of the image
          for (loop = 0, pYBR = (unsigned char *)[ybrData bytes]; loop < size; loop++, pYBR += 3)
          {
            // get the Y, B and R channels from the original image
//            y = (int) pYBR [0];
//            b = (int) pYBR [1];
//            r = (int) pYBR [2];
			a = (int) pYBR [0];
            b = (int) pYBR [1];
            c = (int) pYBR [2];

         R = 38142 *(a-16) + 52298 *(c -128);
         G = 38142 *(a-16) - 26640 *(c -128) - 12845 *(b -128);
         B = 38142 *(a-16) + 66093 *(b -128);

         R = (R+16384)>>15;
         G = (G+16384)>>15;
         B = (B+16384)>>15;

         if (R < 0)   R = 0;
         if (G < 0)   G = 0;
         if (B < 0)   B = 0;
         if (R > 255) R = 255;
         if (G > 255) G = 255;
         if (B > 255) B = 255;


            // red
            *pRGB = R;	//(unsigned char) (y + (1.402 *  r));
            pRGB++;	// move the ptr to the Green
            
            // green
            *pRGB = G;	//(unsigned char) (y - (0.344 * b) - (0.714 * r));
            pRGB++;	// move the ptr to the Blue
            
            // blue
            *pRGB = B;	//(unsigned char) (y + (1.772 * b));
            pRGB++;	// move the ptr to the next Red
            
			} // for ...loop on the elements of the image to convert
		}
		else if ([theKind isEqualToString:@"YBR_FULL_422"])
		{
         // loop on the pixels of the image
		  pYBR = (unsigned char *) [ybrData bytes];
          
		  int yy, x;
		  for( yy = 0; yy < _rows; yy++)	//_rows/2
		  {
			unsigned char	*rr = pRGB;
//			unsigned char	*rr2 = pRGB+3*_columns;
			
			for( x = 0; x < _columns; x++)
			{
				y  = (int) pYBR [0];
				b = (int) pYBR [1];
				r = (int) pYBR [2];
				
				*(rr) = y;
				*(rr+1) = b;
				*(rr+2) = r;
				
//				*(rr2) = y;
//				*(rr2+1) = b;
//				*(rr2+2) = r;
				
				pYBR += 3;
				rr += 3;
//				rr2 += 3;
			}
			
//			pRGB += 2*_columns*3;
			pRGB += _columns*3;
		  }

		}
        else if ([theKind isEqualToString:@"YBR_PARTIAL_422"])
        {
          // loop on the pixels of the image
          for (loop = 0, pYBR = (unsigned char *)[ybrData bytes]; loop < (size / 2); loop++)
          {
            // get the Y, B and R channels from the original image
            y  = (int) pYBR [0];
            y1 = (int) pYBR [1];
            // the Cb and Cr values are sampled horizontally at half the Y rate
            b = (int) pYBR [2];
            r = (int) pYBR [3];
            
            // ***** first pixel *****
            // red 1
            *pRGB = (unsigned char) ((1.1685 * y) + (0.0389 * b) + (1.596 * r));
            pRGB++;	// move the ptr to the Green
            
            // green 1
            *pRGB = (unsigned char) ((1.1685 * y) - (0.401 * b) - (0.813 * r));
            pRGB++;	// move the ptr to the Blue
            
            // blue 1
            *pRGB = (unsigned char) ((1.1685 * y) + (2.024 * b));
            pRGB++;	// move the ptr to the next Red
            
            
            // ***** second pixel *****
            // red 2
            *pRGB = (unsigned char) ((1.1685 * y1) + (0.0389 * b) + (1.596 * r));
            pRGB++;	// move the ptr to the Green
            
            // green 2
            *pRGB = (unsigned char) ((1.1685 * y1) - (0.401 * b) - (0.813 * r));
            pRGB++;	// move the ptr to the Blue
            
            // blue 2
            *pRGB = (unsigned char) ((1.1685 * y1) + (2.024 * b));
            pRGB++;	// move the ptr to the next Red

            // the Cb and Cr values are sampled horizontally at half the Y rate
            pYBR += 4;
            
          } // for ...loop on the elements of the image to convert                
		}  //YBR 422
    //  } // switch ...kind of YBR
	break;
    case 1 : // each plane is stored separately (only allowed for YBR_FULL)
    {
      unsigned char *pY, *pB, *pR;	// ptr to Y, Cb and Cr channels of the original image
      NSLog(@"YBR FULL and planar");  
      // points to the begining of each channel in memory
      pY = (unsigned char *)[ybrData bytes];
      pB = (unsigned char *) (pY + size);
      pR = (unsigned char *) (pB + size);
        
      // loop on the pixels of the image
      for (loop = 0; loop < size; loop++, pY++, pB++, pR++)
      {
	  		a = (int) *pY;
		b = (int) *pB;
		c = (int) *pR;

         R = 38142 *(a-16) + 52298 *(c -128);
         G = 38142 *(a-16) - 26640 *(c -128) - 12845 *(b -128);
         B = 38142 *(a-16) + 66093 *(b -128);

         R = (R+16384)>>15;
         G = (G+16384)>>15;
         B = (B+16384)>>15;

         if (R < 0)   R = 0;
         if (G < 0)   G = 0;
         if (B < 0)   B = 0;
         if (R > 255) R = 255;
         if (G > 255) G = 255;
         if (B > 255) B = 255;
	  
	  
        // red
        *pRGB = R;	//(unsigned char) ((int) *pY + (1.402 *  (int) *pR) - 179.448);
        pRGB++;	// move the ptr to the Green
            
        // green
        *pRGB = G;	//(unsigned char) ((int) *pY - (0.344 * (int) *pB) - (0.714 * (int) *pR) + 135.45);
        pRGB++;	// move the ptr to the Blue
            
        // blue
        *pRGB = B;	//(unsigned char) ((int) *pY + (1.772 * (int) *pB) - 226.8);
        pRGB++;	// move the ptr to the next Red
            

//        // red
//        *pRGB = (unsigned char) ((int) *pY + (1.402 *  (int) *pR) - 179.448);
//        pRGB++;	// move the ptr to the Green
//            
//        // green
//        *pRGB = (unsigned char) ((int) *pY - (0.344 * (int) *pB) - (0.714 * (int) *pR) + 135.45);
//        pRGB++;	// move the ptr to the Blue
//            
//        // blue
//        *pRGB = (unsigned char) ((int) *pY + (1.772 * (int) *pB) - 226.8);
//        pRGB++;	// move the ptr to the next Red
//            
      } // for ...loop on the elements of the image to convert
    } // case 1
	break;
  
  } // switch
    
  return rgbData;
  
}

- (NSData *)convertToFloat:(NSData *)data{
	NSMutableData *floatData = nil;
	float rescaleIntercept = 0.0;
	float rescaleSlope = 1.0;
	vImage_Buffer src16, dstf, src8;
	dstf.height = src16.height = src8.height = _rows;
	dstf.width = src16.width = src8.width = _columns;
	dstf.rowBytes = _columns * sizeof(float);
	
	if ([_dcmObject attributeValueWithName:@"RescaleIntercept" ]  != nil)
            rescaleIntercept = (float)([[_dcmObject attributeValueWithName:@"RescaleIntercept" ] floatValue]);            
	if ([_dcmObject attributeValueWithName:@"RescaleSlope" ] != nil) 
            rescaleSlope = [[_dcmObject attributeValueWithName:@"RescaleSlope" ] floatValue];  
	
	// 8 bit grayscale		
	if (_samplesPerPixel == 1 && _pixelDepth <= 8){
		src8.rowBytes = _columns * sizeof(char);
		src8.data = (unsigned char *)[data bytes];
		floatData = [NSMutableData dataWithLength:[data length] * sizeof(float)/sizeof(char)];
		dstf.data = (float *)[floatData mutableBytes];
		vImageConvert_Planar8toPlanarF (&src8, &dstf, 0, 256,0);		
	}
	// 16 bit signed
	else if (_samplesPerPixel == 1 && _pixelDepth <= 16 && _isSigned){
		src16.rowBytes = _columns * sizeof(short);
		src16.data = (short *)[data bytes];
		floatData = [NSMutableData dataWithLength:[data length]  * sizeof(float)/sizeof(short)];
		dstf.data = (float *)[floatData mutableBytes];
		vImageConvert_16SToF ( &src16, &dstf, rescaleIntercept, rescaleSlope, 0); 		
	}
	//16 bit unsigned
	else if (_samplesPerPixel == 1 && _pixelDepth <= 16 && !(_isSigned)){
		
		src16.rowBytes = _columns * sizeof(short);
		src16.data = (unsigned short *)[data bytes];
		floatData = [NSMutableData dataWithLength:[data length] * sizeof(float)/sizeof(unsigned short)];
		dstf.data = (float *)[floatData mutableBytes];
		vImageConvert_16UToF ( &src16, &dstf, rescaleIntercept, rescaleSlope, 0); 		
	}
	//rgb 8 bit interleaved
	else if (_samplesPerPixel > 1 && _pixelDepth <= 8){
		//convert to ARGB first
		src8.rowBytes = _columns * sizeof(char) * 3;
		src8.data = (unsigned char *)[data bytes];
		vImage_Buffer argb;
		argb.height = _rows;
		argb.width = _columns;
		argb.rowBytes = _columns * sizeof(char) * 4;
		NSMutableData *argbData = [NSMutableData dataWithLength:_rows * _columns * 4];
		argb.data = (unsigned char *)[argbData mutableBytes];
		vImageConvert_RGB888toARGB8888 (&src8,  //src
										NULL,	//alpha src
										0,	//alpha
										&argb,	//dst
										0, 0);		//flags need a extra arg for some reason
										

		floatData = [NSMutableData dataWithLength:[argbData length]  * sizeof(float)/sizeof(char)];
		dstf.data = (float *)[floatData mutableBytes];
		vImageConvert_Planar8toPlanarF (&argb, &dstf, 0, 256, 0);	
	}
	else if( _pixelDepth == 32)
	{
		unsigned int	*uslong = (unsigned int*) [data bytes];
		int				*slong = (int*) [data bytes];
		floatData = [NSMutableData dataWithLength:[data length]];
		float			*tDestF = (float *)[floatData mutableBytes];
	
		
		if(_isSigned)
		{
			long x = _rows * _columns;
			while( x-->0)
			{
				*tDestF++ = ((float) (*slong++)) * rescaleSlope + rescaleIntercept;
			}
		}
		else
		{
			long x = _rows * _columns;
			while( x-->0)
			{
				*tDestF++ = ((float) (*uslong++)) * rescaleSlope + rescaleIntercept;
			}
		}

	}


	
	return floatData;	
}
- (NSData *)convertDataToRGBColorSpace:(NSData *)data
{
	NSData *rgbData = nil;
	NSString *colorspace = [_dcmObject attributeValueWithName:@"PhotometricInterpretation"];
	BOOL isPlanar = [[_dcmObject attributeValueWithName:@"PlanarConfiguration"] intValue];
	if ([colorspace hasPrefix:@"YBR"])
		rgbData = [self convertYBrToRGB:data kind:colorspace isPlanar:isPlanar];
	else if ([colorspace hasPrefix:@"PALETTE"])
		rgbData = [self  convertPaletteToRGB:data];
	else
		rgbData = data;
	
	return rgbData;
}

- (void)convertToRGBColorspace{
	//NSLog(@"convert tp RGB colorspace");
	NSString *colorspace = [_dcmObject attributeValueWithName:@"PhotometricInterpretation"];
	BOOL isPlanar = [[_dcmObject attributeValueWithName:@"PlanarConfiguration"] intValue];
	NSMutableArray *newValues = [NSMutableArray array];
	if ([colorspace hasPrefix:@"YBR"]){
		for ( NSMutableData *data in _values ) {
			[newValues addObject:[self convertYBrToRGB:data kind:colorspace isPlanar:isPlanar]];
		}
		[_values release];
		_values = [newValues retain];
		[_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:@"RGB"] forName:@"PhotometricInterpretation"];
	}
	else if ([colorspace hasPrefix:@"PALETTE"]){
	
		for ( NSMutableData *data in _values ) {
			[newValues addObject:[self convertPaletteToRGB:data]];
		}
		[_values release];
		_values = [newValues retain];
		//remove PAlette stuff
		NSMutableDictionary *attributes = [_dcmObject attributes];
		NSMutableArray *keysToRemove = [NSMutableArray array];
		for ( NSString *key in attributes ) {
			DCMAttribute *attr = [attributes objectForKey:key];
			if ([(DCMAttributeTag *)[attr attrTag] group] == 0x0028 && ([(DCMAttributeTag *)[attr attrTag] element] > 0x1100 && [(DCMAttributeTag *)[attr attrTag] element] <= 0x1223))
				[keysToRemove addObject:key];
			}
		[attributes removeObjectsForKeys:keysToRemove];
		[_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:@"RGB"] forName:@"PhotometricInterpretation"];
		[_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithInt:8]] forName:@"BitsStored"];
		_pixelDepth = 8;
	}
	
}

- (NSMutableData *)createFrameAtIndex:(int)index{
	
	//NSDate *timestamp = [NSDate date];
	NSMutableData *subData = nil;
	if (!_framesCreated){	
		//NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		if ( transferSyntax.isEncapsulated )
		{
			//NSLog(@"encapsulated");
			NSMutableArray *offsetTable = [NSMutableArray array];
			/*offset table will be first fragment
				if single image value = 0;
				each offset is an unsigned long to the first byte of the Item tag. We have already removed the tags.
				The 0 frame starts on 0
				the 1 frame starts of offset - 8  ( Two Item tag and lengths)
				The 2 frame starts at offset - 16   ( three Item tag and lengths)
				So will use 0 for first frame, and then  subtract (n-1) * 8
			*/
			int startMerge = 0;
			unsigned  long offset;
			if ([_values count] > 1  && [(NSData *)[_values objectAtIndex:0] length] > 0) {
				startMerge = 1;
				int i;
				NSData *offsetData = [_values objectAtIndex:0];
				unsigned long *offsets = (unsigned long *)[offsetData bytes];
				int numberOfOffsets = [offsetData length]/4;
				for ( i = 0; i < numberOfOffsets; i++)
				{
					if ( transferSyntax.isLittleEndian ) 
						offset = NSSwapLittleLongToHost(offsets[i]);
					else
						offset = offsets[i];
					[offsetTable addObject:[NSNumber numberWithLong:offset]];
				}
			}
			else 
				[offsetTable addObject:[NSNumber numberWithLong:0]];

			
			//most likely way to have data with one frame per data object.
			NSMutableArray *values = [NSMutableArray arrayWithArray:_values];
			//remove offset table
			[values removeObjectAtIndex:0];
			if ([values count] == _numberOfFrames)
			{
				subData = [values objectAtIndex:index];
				//need to figure out where the data starts and ends
			}
			else
			{
				int currentOffset = [[offsetTable objectAtIndex:index] longValue];
				int currentLength = 0;
				if (index < _numberOfFrames - 1 && index < [offsetTable count] - 1)
					currentLength =  [[offsetTable objectAtIndex:index + 1] longValue] - currentOffset;
				else{
					//last offset - currentLength =  total length of items 
					int itemsLength = 0;
					for ( NSData *aData in values )
						itemsLength += [aData length];
					currentLength = itemsLength - currentOffset;
				}
				/*now we need to find the item that == the start of the offset
					find which items contain the data.
					need to add for item tag and length 8 bytes * (n - 1) items
				*/
				int combinedLength = 0;
				int startingItem = 0;
				int dataLength = 0;
				int endItem = 0;
				while (combinedLength < currentOffset && startingItem < [values count]) {
					combinedLength += ([(NSData *)[values objectAtIndex:startingItem] length] + 8);
					startingItem++;
				}
				endItem = startingItem;
				dataLength = ([(NSData *)[values objectAtIndex:endItem] length] + 8);
				while ((dataLength < currentLength) && (endItem < [values count])) {
					endItem++;
					dataLength += ([(NSData *)[values objectAtIndex:endItem] length] + 8);
				}
				int j;
				subData = [NSMutableData data];
				for (j = startingItem; j <= endItem ; j++) 
					[subData appendData:[values objectAtIndex:j]];	
			} //appending fragments

		} //end encapsulated
		//multiple frames
		else if (_numberOfFrames > 1) {
			int depth = 1;
			if (_bitsStored <= 8) 
				depth = 1;
			else if (_bitsStored  <= 16)
				depth = 2;
			else
				depth = 4;
			int frameLength = _rows * _columns * _samplesPerPixel * depth;
			NSRange range = NSMakeRange(index * frameLength, frameLength);
			NSData *subdata = [[_values objectAtIndex:0]  subdataWithRange:range];
			subData = [[subdata mutableCopy] autorelease];
		}
		//only one fame
		else {
			
			subData =[_values objectAtIndex:0];
		}
	}		
	return subData;
}

- (void)createFrames{
	
	if (!_framesCreated){
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		if (DCMDEBUG)
			NSLog(@"Decode Data");
		// if encapsulated we need to use offset table to create frames
		if ( transferSyntax.isEncapsulated ) {
			if (DCMDEBUG)
				NSLog(@"Data is encapsulated");
			NSMutableArray *offsetTable = [NSMutableArray array];
			/*offset table will be first fragment
				if single image value = 0;
				each offset is an unsigned long to the first byte of the Item tag. We have already removed the tags.
				The 0 frame starts on 0
				the 1 frame starts of offset - 8  ( Two Item tag and lengths)
				The 2 frame starts at offset - 16   ( three Item tag and lengths)
				So will use 0 for first frame, and then  subtract (n-1) * 8
			*/
			unsigned  long offset;
				
			
			int startMerge = 0;

			if ([_values count] > 1  && [(NSData *)[_values objectAtIndex:0] length] > 0) {
				startMerge = 1;
				int i;
				NSData *offsetData = [_values objectAtIndex:0];
				unsigned long *offsets = (unsigned long *)[offsetData bytes];
				int numberOfOffsets = [offsetData length]/4;
				for ( i = 0; i < numberOfOffsets; i++) {
					if ( transferSyntax.isLittleEndian ) 
						offset = NSSwapLittleLongToHost(offsets[i]);
					else
						offset = offsets[i];
					[offsetTable addObject:[NSNumber numberWithLong:offset]];
				}
			}
			else 
				[offsetTable addObject:[NSNumber numberWithLong:0]];

		
			
			//most likely way to have data with one frame per data object.
			NSMutableArray *values = [NSMutableArray arrayWithArray:_values];
			//remove offset table
			[values removeObjectAtIndex:0];
			
			[_values removeAllObjects];
			int i;
			NSMutableData *subData;
			if (DCMDEBUG)
				NSLog(@"number of Frames: %d", _numberOfFrames);
			for (i = 0; i < _numberOfFrames; i++) {	
				if (DCMDEBUG)
					NSLog(@"Frame %d", i);
				//one to one match between frames and items
				
				if ([values count] == _numberOfFrames) {
					subData = [values objectAtIndex:i];
				}
				
				//need to figure out where the data starts and ends
				else{
				
					int currentOffset = [[offsetTable objectAtIndex:i] longValue];
					int currentLength = 0;
					if (i < _numberOfFrames - 1)
						currentLength =  [[offsetTable objectAtIndex:i + 1] longValue] - currentOffset;
					else{
						//last offset - currentLength =  total length of items 
						int itemsLength = 0;
						for ( NSData *aData in values )
							itemsLength += [aData length];
						currentLength = itemsLength - currentOffset;
					}
					/*now we need to find the item that == the start of the offset
						find which items contain the data.
						need to add for item tag and length 8 bytes * (n - 1) items
					*/
					int combinedLength = 0;
					int startingItem = 0;
					int dataLength = 0;
					int endItem = 0;
					while (combinedLength < currentOffset && startingItem < [values count]) {
						combinedLength += ([(NSData *)[values objectAtIndex:startingItem] length] + 8);
						startingItem++;
					}
					endItem = startingItem;
					dataLength = ([(NSData *)[values objectAtIndex:endItem] length] + 8);
					while ((dataLength < currentLength) && (endItem < [values count])) {
						endItem++;
						dataLength += ([(NSData *)[values objectAtIndex:endItem] length] + 8);
					}
					subData = [NSMutableData data];
					for ( int j = startingItem; j <= endItem ; j++ ) 
						[subData appendData:[values objectAtIndex:j]];	
				}
				//subdata is new frame;
				[self addFrame:subData];
			}
		}
		else{
		if (_numberOfFrames > 0) {
				//need to parse data into separate frame NSData objects:
				//NSDate *timeStamp = [NSDate date];
				//NSLog(@"Start create Frames: %f", -[timeStamp timeIntervalSinceNow]);
				int depth = 1;
				if (_pixelDepth <= 8) 
					depth = 1;
				else if (_pixelDepth  <= 16)
					depth = 2;
				else
					depth = 4;
				int frameLength = _rows * _columns * _samplesPerPixel * depth;
				NSMutableData *rawData = [[[_values objectAtIndex:0] retain] autorelease];
				[_values removeAllObjects];
				for ( unsigned int i = 0; i < _numberOfFrames; i++ ) {
					NSAutoreleasePool *subPool = [[NSAutoreleasePool alloc] init];
					//NSLog(@"create Frame %d: %f", i , -[timeStamp timeIntervalSinceNow]);
					NSRange range = NSMakeRange(i * frameLength, frameLength);
					NSMutableData *data = [NSMutableData dataWithData:[rawData subdataWithRange:range]];
					[self addFrame:data];
					[subPool release];
				}
			}
		}
			
		_framesCreated = YES;
		[pool release];
	}
}

- (NSData *)decodeFrameAtIndex:(int)index
{
	[singleThread lock];
	
	BOOL colorspaceIsConverted = NO;
	NSMutableData *subData = nil;
	
	@try
	{
		if( _framesCreated)
			subData = [_values objectAtIndex:index];
		else
			subData = [self createFrameAtIndex:index];
	}
	@catch (NSException *e)
	{
		NSLog( @"exception decodeFrameAtIndex: %@", e);
		[singleThread unlock];
		
		return nil;
	}
	
	if ([_values count] > 0 && index < _numberOfFrames)
	{
		if( _framesDecoded == nil)
		{
			_framesDecoded = [[NSMutableArray array] retain];
			for( int i = 0; i < _numberOfFrames; i++)
				[_framesDecoded addObject: [NSNumber numberWithBool: NO]];
		}
		else if( [_framesDecoded count] != _numberOfFrames)
		{
			int s = [_framesDecoded count];
			for( int i = s; i <= _numberOfFrames; i++)
				[_framesDecoded addObject: [NSNumber numberWithBool: NO]];
		}
		
		if (DCMDEBUG)
			NSLog(@"to decoders:%@", transferSyntax.description );
		
		// data to decoders
		NSData *data = subData;
		
		if( transferSyntax.isEncapsulated == YES)
		{
			short depth = 0;
			
			if( JasperInitialized == NO)
			{
				JasperInitialized = YES;
				jas_init();
			}
			
			[singleThread unlock];
			
			if( [transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEG2000LosslessTransferSyntax]] == NO &&
				[transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEG2000LossyTransferSyntax]]  == NO && 
				[transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax RLETransferSyntax]] == NO)
			{
				depth = scanJpegDataForBitDepth( (unsigned char *) [subData bytes], [subData length]);
				if( depth == 0)
					depth = _pixelDepth;
			}
			
			if ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEGBaselineTransferSyntax]])
			{
				data = [self convertJPEG8ToHost:subData];
				colorspaceIsConverted = YES;
			}
			// 8 bit jpegs
			else if ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEGExtendedTransferSyntax]] && depth <= 8)
			{
				colorspaceIsConverted = YES;
				data = [self convertJPEG8ToHost:subData];
			}
			else if ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEGLosslessTransferSyntax]] && depth <= 8)
			{
				data = [self convertJPEG8LosslessToHost:subData];
			}
			else if ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEGLossless14TransferSyntax]] && depth <= 8)
			{ 
				data = [self convertJPEG8LosslessToHost:subData];
			}
			//12 bit jpegs
			else if ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEGExtendedTransferSyntax]] && depth <= 12)
			{
				data = [self convertJPEG12ToHost:subData];
			}
			else if ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEGLosslessTransferSyntax]] && depth <= 12)
			{
				data = [self convertJPEG12ToHost:subData];
			}
			else if ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEGLossless14TransferSyntax]] && depth <= 12)
			{
				data = [self convertJPEG12ToHost:subData];
			}
			//jpeg 16s
			else if ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEGExtendedTransferSyntax]] && depth <= 16)
			{
				data = [self convertJPEG16ToHost:subData];		
			}
			else if ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEGLosslessTransferSyntax]] && depth <= 16)
			{
				data = [self convertJPEG16ToHost:subData];
			}
			else if ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEGLossless14TransferSyntax]] && depth <= 16)
			{
				data = [self convertJPEG16ToHost:subData];		
			}
			//JPEG 2000
			else if ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEG2000LosslessTransferSyntax]] || [transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEG2000LossyTransferSyntax]] )
			{
				colorspaceIsConverted = YES;
				data = [self convertJPEG2000ToHost:subData];
			}
			else if ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax RLETransferSyntax]])
			{
				data = [self convertRLEToHost:subData];
			}
			else
			{
				NSLog(@"Unknown compressed transfer syntax: %@ %@", transferSyntax.description, transferSyntax.transferSyntax);
			}
			
			[singleThread lock];
		}
		
		//non encapsulated
		if( transferSyntax.isEncapsulated == NO && _bitsStored > 8)
		{
			if( [[_framesDecoded objectAtIndex: index] boolValue] == NO)
			{
				//Little Endian Data and BigEndian Host
				if ((NSHostByteOrder() == NS_BigEndian) && ([transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax ImplicitVRLittleEndianTransferSyntax]] || [transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax]]))
				{
					data = [self convertDataFromLittleEndianToHost:subData];
					[_framesDecoded replaceObjectAtIndex: index withObject: [NSNumber numberWithBool: YES]];
				}
				//Big Endian Data and little Endian host
				else  if ((NSHostByteOrder() == NS_LittleEndian) && [transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax ExplicitVRBigEndianTransferSyntax]])
				{
					data = [self convertDataFromBigEndianToHost:subData];
					[_framesDecoded replaceObjectAtIndex: index withObject: [NSNumber numberWithBool: YES]];
				}
			}
		}
		
		[singleThread unlock];
		
		NSString *colorspace = [_dcmObject attributeValueWithName:@"PhotometricInterpretation"];
		if (([colorspace hasPrefix:@"YBR"] || [colorspace hasPrefix:@"PALETTE"]) && !colorspaceIsConverted)
		{
			data = [self convertDataToRGBColorSpace:data];	
		}
		else
		{
			int numberofPlanes = [[_dcmObject attributeValueWithName:@"PlanarConfiguration"] intValue];			
			if (numberofPlanes > 0 && numberofPlanes <= 4)
			{
				if( [transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEGExtendedTransferSyntax]] || [transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEGLosslessTransferSyntax]] || [transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEG2000LosslessTransferSyntax]] || [transferSyntax isEqualToTransferSyntax:[DCMTransferSyntax JPEG2000LossyTransferSyntax]])
				{
					[_dcmObject setAttributeValues:[NSArray arrayWithObject: [NSNumber numberWithInt: 0]] forName:@"PlanarConfiguration"];
				}
				else data = [self interleavePlanesInData:data];
			}
		}
		
		return data;
	}
	else
	{
		[singleThread unlock];
		return nil;
	}
	
	return nil;
}

- (NSImage *)imageAtIndex:(int)index ww:(float)ww  wl:(float)wl{
	float min;
	float max;
	//NSLog(@"pre ww: %f wl:%f", ww, wl);
	//get min and max
	if (ww == 0.0 && wl == 0.0) {
		ww = [[_dcmObject attributeValueWithName:@"WindowWidth"] floatValue]; 
		wl = [[_dcmObject attributeValueWithName:@"WindowCenter"] floatValue]; 
			//NSLog(@"ww: %f  wl: %f", ww, wl);
	}
	min = wl - ww/2;
	max = wl + ww/2;
	
	NSData *data = [self decodeFrameAtIndex:(int)index];
	NSImage *image = [[[NSImage alloc] init] autorelease];
	float rescaleIntercept, rescaleSlope;
	int spp;
	unsigned char *bmd;
	NSString *colorSpaceName;
	
	if ([_dcmObject attributeValueWithName:@"RescaleIntercept"] != nil)
            rescaleIntercept = ([[_dcmObject attributeValueWithName:@"RescaleIntercept"] floatValue]);
	else 
            rescaleIntercept = 0.0;
            
    //rescale Slope
	if ([_dcmObject attributeValueWithName:@"RescaleSlope" ] != nil) 
		rescaleSlope = [[_dcmObject attributeValueWithName:@"RescaleSlope" ] floatValue];
        
	else 
		rescaleSlope = 1.0;
		// color 
	NSString *pi = [_dcmObject attributeValueWithName:@"PhotometricInterpretation"]; 
	if ([pi isEqualToString:@"RGB"] || ([pi hasPrefix:@"YBR"] || [pi isEqualToString:@"PALETTE"]) ) {
		bmd = (unsigned char *)[data bytes];
		spp = 3;
		colorSpaceName = NSCalibratedRGBColorSpace;
	
	}
	// 8 bit gray
	else if (_pixelDepth <= 8) {
		bmd = (unsigned char *)[data bytes];
		spp = 1;
		colorSpaceName = NSCalibratedBlackColorSpace;
	}
	//16 bit gray
	else {
	//convert to Float
		
		NSMutableData *data8 = [NSMutableData dataWithLength:_rows*_columns];
		vImage_Buffer src16, dstf, dst8;
		dstf.height = src16.height = dst8.height=  _rows;
		dstf.width = src16.width = dst8.width =  _columns;
		src16.rowBytes = _columns*2;
		dstf.rowBytes = _columns*sizeof(float);
		dst8.rowBytes = _columns;
		
		src16.data = (unsigned short *)[data bytes];
		dstf.data = malloc(_rows*_columns * sizeof(float) + 100);
		dst8.data = (unsigned char *)[data8 mutableBytes];
		if (_isSigned)
			vImageConvert_16SToF( &src16, &dstf, rescaleIntercept, rescaleSlope, 0);
		else
			vImageConvert_16UToF( &src16, &dstf, rescaleIntercept, rescaleSlope, 0);
			
		
		vImageConvert_PlanarFtoPlanar8 (
				 &dstf, 
				 &dst8, 
				max, 
				min, 
				0		
		);
		//NSLog(@"max %f min: %f intercept: %f, slope: %f", max, min, rescaleIntercept, rescaleSlope);
		free(dstf.data);	
		bmd = (unsigned char*) dst8.data;
		spp =1;
		colorSpaceName = NSCalibratedWhiteColorSpace;
		
	}
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:&bmd
	pixelsWide:_columns 
	pixelsHigh:_rows 
	bitsPerSample:8 
	samplesPerPixel:spp 
	hasAlpha:NO 
	isPlanar:NO 
	colorSpaceName:colorSpaceName 		
	bytesPerRow:0
	bitsPerPixel:0];
				
	[image addRepresentation:rep];
	return image;
}

/*
- (NSXMLNode *)xmlNode{
	NSXMLNode *myNode;
	NSXMLNode *groupAttr = [NSXMLNode attributeWithName:@"group" stringValue:[NSString stringWithFormat:@"%04x",[[self tag] group]]];
	NSXMLNode *elementAttr = [NSXMLNode attributeWithName:@"element" stringValue:[NSString stringWithFormat:@"%04x",[[self tag] element]]];
	NSXMLNode *vrAttr = [NSXMLNode attributeWithName:@"vr" stringValue:[[self tag] vr]];
	NSArray *attrs = [NSArray arrayWithObjects:groupAttr,elementAttr, vrAttr, nil];
	NSEnumerator *enumerator = [[self values] objectEnumerator];
	id value;
	//NSMutableArray *elements = [NSMutableArray array];

	
	myNode = [NSXMLNode elementWithName:@"element" children:nil attributes:attrs];
	return myNode;
}
*/

@end
