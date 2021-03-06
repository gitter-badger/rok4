# Copyright © (2011) Institut national de l'information
#                    géographique et forestière 
# 
# Géoportail SAV <geop_services@geoportail.fr>
# 
# This software is a computer program whose purpose is to publish geographic
# data using OGC WMS and WMTS protocol.
# 
# This software is governed by the CeCILL-C license under French law and
# abiding by the rules of distribution of free software.  You can  use, 
# modify and/ or redistribute the software under the terms of the CeCILL-C
# license as circulated by CEA, CNRS and INRIA at the following URL
# "http://www.cecill.info". 
# 
# As a counterpart to the access to the source code and  rights to copy,
# modify and redistribute granted by the license, users are provided only
# with a limited warranty  and the software's author,  the holder of the
# economic rights,  and the successive licensors  have only  limited
# liability. 
# 
# In this respect, the user's attention is drawn to the risks associated
# with loading,  using,  modifying and/or developing or reproducing the
# software by the user in light of its specific status of free software,
# that may mean  that it is complicated to manipulate,  and  that  also
# therefore means  that it is reserved for developers  and  experienced
# professionals having in-depth computer knowledge. Users are therefore
# encouraged to load and test the software's suitability as regards their
# requirements in conditions enabling the security of their systems and/or 
# data to be ensured and,  more generally, to use and operate it in the 
# same conditions as regards security. 
# 
# The fact that you are presently reading this means that you have had
# 
# knowledge of the CeCILL-C license and that you accept its terms.

################################################################################

=begin nd
File: DataSource.pm

Class: BE4::DataSource

Manage a data source, physical (image files) or virtual (WMS server) or both.

Using:
    (start code)
    use BE4::DataSource;

    # DataSource object creation : 3 cases

    # Real Data and no harvesting : native SRS and lossless compression
    my $objDataSource = BE4::DataSource->new(
        "19",
        {
            srs => "IGNF:LAMB93",
            path_image => "/home/ign/DATA/BDORTHO"
        }
    );

    # No Data, just harvesting (here for a WMS vector) 
    my $objDataSource = BE4::DataSource->new(
        "19",
        {
            srs => IGNF:WGS84G,
            extent => /home/ign/SHAPE/WKTPolygon.txt,

            wms_layer   => "tp:TRONCON_ROUTE",
            wms_url => "http://geoportail/wms/",
            wms_version => "1.3.0",
            wms_request => "getMap",
            wms_format  => "image/png",
            wms_bgcolor => "0xFFFFFF",
            wms_transparent  => "FALSE",
            wms_style  => "line",
            min_size => 9560,
            max_width => 1024,
            max_height => 1024
        }
    );
    
    # No Data, just harvesting provided images
    my $objDataSource = BE4::DataSource->new(
        "19",
        {
            srs => IGNF:WGS84G,
            list => /home/ign/listIJ.txt,

            wms_layer   => "tp:TRONCON_ROUTE",
            wms_url => "http://geoportail/wms/",
            wms_version => "1.3.0",
            wms_request => "getMap",
            wms_format  => "image/png",
            wms_bgcolor => "0xFFFFFF",
            wms_transparent  => "FALSE",
            wms_style  => "line",
            min_size => 9560,
            max_width => 1024,
            max_height => 1024
        }
    );

    # Real Data and harvesting : reprojection or lossy compression
    my $objDataSource = BE4::DataSource->new(
        "19",
        {
            srs => "IGNF:LAMB93",
            path_image => "/home/ign/DATA/BDORTHO"
            wms_layer => "ORTHO_XXX",
            wms_url => "http://geoportail/wms/",
            wms_version => "1.3.0",
            wms_request => "getMap",
            wms_format => "image/tiff"
        }
    );
    (end code)

Attributes:
    bottomID - string - Level identifiant, from which data source is used (base level).
    bottomOrder - integer - Level order, from which data source is used (base level).
    topID - string - Level identifiant, to which data source is used. It is calculated in relation to other datasource.
    topOrder - integer - Level order, to which data source is used. It is calculated in relation to other datasource.

    srs - string - SRS of the bottom extent (and ImageSource objects if exists).
    extent - <OGR::Geometry> - Precise extent, in the previous SRS (can be a bbox). It is calculated from the <ImageSource> or supplied in configuration file. 'extent' is mandatory (a bbox or a file which contains a WKT geometry) if there are no images. We have to know area to harvest. If images, extent is calculated thanks data.
    list - string - File path, containing a list of image indices (I,J) to harvest.
    bbox - double array - Data source bounding box, in the previous SRS : [xmin,ymin,xmax,ymax].

    imageSource - <ImageSource> - Georeferenced images' source.
    harvesting - <Harvesting> - WMS server. If it is useless, it will be remove.

Limitations:
    Metadata managing not yet implemented.
=cut

################################################################################

package BE4::DataSource;

use strict;
use warnings;

use Log::Log4perl qw(:easy);
use Data::Dumper;
use List::Util qw(min max);

use Geo::GDAL;

# My module
use BE4::ImageSource;
use BE4::Harvesting;

require Exporter;
use AutoLoader qw(AUTOLOAD);

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw() ] );
our @EXPORT_OK   = ( @{$EXPORT_TAGS{'all'}} );
our @EXPORT      = qw();

################################################################################
# Constantes
use constant TRUE  => 1;
use constant FALSE => 0;

################################################################################

BEGIN {}
INIT {}
END {}

####################################################################################################
#                                        Group: Constructors                                       #
####################################################################################################

=begin nd
Constructor: new

DataSource constructor. Bless an instance.

Parameters (list):
    level - string - Base level (bottom) for this data source.
    params - hash - Data source parameters (see <_load> for details).

See also:
    <_load>, <computeGlobalInfo>
=cut
sub new {
    my $this = shift;
    my $level = shift;
    my $params = shift;

    my $class= ref($this) || $this;
    # IMPORTANT : if modification, think to update natural documentation (just above) and pod documentation (bottom)
    my $self = {
        # Global information
        bottomID => undef,
        bottomOrder => undef,
        topID => undef,
        topOrder => undef,
        bbox => undef,
        list => undef,
        extent => undef,
        srs => undef,
        # Image source
        imageSource => undef,
        # Harvesting
        harvesting => undef,
    };

    bless($self, $class);

    TRACE;

    # load. class
    return undef if (! $self->_load($level,$params));

    return undef if (! $self->computeGlobalInfo());

    return $self;
}

=begin nd
Function: _load

Sorts parameters, relays to concerned constructors and stores results.

(see datasource.png)

Parameters (list):
    level - string - Base level (bottom) for this data source.
    params - hash - Data source parameters :
    (start code)
            # common part
            srs - string

            # image source part
            path_image          - string
            path_metadata       - string
            preprocess_command  - string
            preprocess_opt_beg  - string
            preprocess_opt_mid  - string
            preprocess_opt_end  - string
            preprocess_tmp_dir  - string

            # harvesting part
            wms_layer - string
            wms_url - string
            wms_version - string
            wms_request - string
            wms_format - string
            wms_bgcolor - string
            wms_transparent - string
            wms_style - string
            min_size - string
            max_width - string
            max_height - string
    (end code)
    This hash is directly and entirely relayed to <ImageSource::new> (even though only common and harvesting parts will be used) and harvesting part is directly relayed to <Harvesting::new> (see parameters' meaning).
=cut
sub _load {
    my $self   = shift;
    my $level = shift;
    my $params = shift;

    TRACE;
    
    return FALSE if (! defined $params);

    if (! defined $level || $level eq "") {
        ERROR("A data source have to be defined with a level !");
        return FALSE;
    }
    $self->{bottomID} = $level;

    if (! exists $params->{srs} || ! defined $params->{srs}) {
        ERROR("A data source have to be defined with the 'srs' parameter !");
        return FALSE;
    }
    $self->{srs} = $params->{srs};

    # bbox is optionnal if we have an ImageSource (checked in computeGlobalInfo)
    if (exists $params->{extent} && defined $params->{extent}) {
        $self->{extent} = $params->{extent};
    }
    
    if (exists $params->{list} && defined $params->{list}) {
        $self->{list} = $params->{list};
    }

    # ImageSource is optionnal
    my $imagesource = undef;
    if (exists $params->{path_image}) {
        $imagesource = BE4::ImageSource->new($params);
        if (! defined $imagesource) {
            ERROR("Cannot create the ImageSource object");
            return FALSE;
        }
    }
    $self->{imageSource} = $imagesource;

    # Harvesting is optionnal, but if we have 'wms_layer' parameter, we suppose that we have others
    my $harvesting = undef;
    if (exists $params->{wms_layer}) {
        $harvesting = BE4::Harvesting->new($params);
        if (! defined $harvesting) {
            ERROR("Cannot create the Harvesting object");
            return FALSE;
        }
    }
    $self->{harvesting} = $harvesting;
    
    if (! defined $harvesting && ! defined $imagesource) {
        ERROR("A data source must have a ImageSource OR a Harvesting !");
        return FALSE;
    }
    
    return TRUE;
}

=begin nd
Function: computeGlobalInfo

Reads the srs, manipulates extent and bounding box.

If an extent is supplied (no image source), 2 cases are possible :
    - extent is a bbox, as xmin,ymin,xmax,ymax
    - extent is a file path, file contains a complex polygon, WKT format.

We generate an OGR Geometry from the supplied extent or the image source bounding box.
=cut
sub computeGlobalInfo {
    my $self = shift;

    TRACE;

    # Bounding polygon
    if (defined $self->{imageSource}) {
        # We have real images for source, bbox will be calculated from them.
        my ($xmin,$ymin,$xmax,$ymax);

        my @BBOX = $self->{imageSource}->computeBBox();
        $xmin = $BBOX[0] if (! defined $xmin || $xmin > $BBOX[0]);
        $ymin = $BBOX[1] if (! defined $ymin || $ymin > $BBOX[1]);
        $xmax = $BBOX[2] if (! defined $xmax || $xmax < $BBOX[2]);
        $ymax = $BBOX[3] if (! defined $ymax || $ymax < $BBOX[3]);

        $self->{extent} = sprintf "%s,%s,%s,%s",$xmin,$ymin,$xmax,$ymax;
    }
    
    if (defined $self->{extent}) {
        # On a des images, une bbox ou une géométrie WKT pour définir la zone de génération

        my $WKTextent;

        $self->{extent} =~ s/ //;
        my @limits = split (/,/,$self->{extent},-1);

        if (scalar @limits == 4) {
            # user supplied a BBOX
            if ($limits[0] !~ m/[+-]?\d+\.?\d*/ || $limits[1] !~ m/[+-]?\d+\.?\d*/ ||
                $limits[2] !~ m/[+-]?\d+\.?\d*/ || $limits[3] !~ m/[+-]?\d+\.?\d*/ ) {
                ERROR(sprintf "If 'extent' is a bbox, value must be a string like 'xmin,ymin,xmax,ymax' : %s !",$self->{extent});
                return FALSE ;
            }

            my $xmin = $limits[0];
            my $ymin = $limits[1];
            my $xmax = $limits[2];
            my $ymax = $limits[3];

            if ($xmax <= $xmin || $ymax <= $ymin) {
                ERROR(sprintf "'box' value is not logical for a bbox (max < min) : %s !",$self->{extent});
                return FALSE ;
            }

            $WKTextent = sprintf "POLYGON((%s %s,%s %s,%s %s,%s %s,%s %s))",
                $xmin,$ymin,
                $xmin,$ymax,
                $xmax,$ymax,
                $xmax,$ymin,
                $xmin,$ymin;

        }
        elsif (scalar @limits == 1) {
            # user supplied a file which contains bounding polygon
            if (! -f $self->{extent}) {
                ERROR (sprintf "Shape file ('%s') doesn't exist !",$self->{extent});
                return FALSE;
            }

            if (! open SHAPE, "<", $self->{extent} ){
                ERROR(sprintf "Cannot open the shape file %s.",$self->{extent});
                return FALSE;
            }

            $WKTextent = '';
            while( defined( my $line = <SHAPE> ) ) {
                $WKTextent .= $line;
            }
            close(SHAPE);
        } else {
            ERROR(sprintf "The value for 'extent' is not valid (must be a BBOX or a file with a WKT shape) : %s.",
                $self->{extent});
            return FALSE;
        }

        if (! defined $WKTextent) {
            ERROR(sprintf "Cannot define the string from the parameter 'extent' (WKT) => %s.",$self->{extent});
            return FALSE;
        }

        # We use extent to define a WKT string, Now, we store in this attribute the equivalent OGR Geometry
        $self->{extent} = undef;

        eval { $self->{extent} = Geo::OGR::Geometry->create(WKT=>$WKTextent); };
        if ($@) {
            ERROR(sprintf "WKT geometry (%s) is not valid : %s",$WKTextent,$@);
            return FALSE;
        }

        if (! defined $self->{extent}) {
            ERROR(sprintf "Cannot create a Geometry from the string : %s.",$WKTextent);
            return FALSE;
        }

        my $bboxref = $self->{extent}->GetEnvelope();
        my ($xmin,$xmax,$ymin,$ymax) = ($bboxref->[0],$bboxref->[1],$bboxref->[2],$bboxref->[3]);
        if (! defined $xmin) {
            ERROR("Cannot calculate bbox from the OGR Geometry");
            return FALSE;
        }
        $self->{bbox} = [$xmin,$ymin,$xmax,$ymax];
    } elsif (defined $self->{list}) {
        # On a fourni un fichier contenant la liste des images (I et J) à générer
        
        my $file = $self->{list};
        
        if (! -e $file) {
            ERROR("Parameter 'list' value have to be an existing file ($file)");
            return FALSE ;
        }
        
        
    } else {
        ERROR("'extent' or 'list' required in the sources configuration file if no image source !");
        return FALSE ;
    }

    return TRUE;

}

####################################################################################################
#                                Group: Getters - Setters                                          #
####################################################################################################

# Function: getSRS
sub getSRS {
    my $self = shift;
    return $self->{srs};
}

# Function: getExtent
sub getExtent {
    my $self = shift;
    return $self->{extent};
}

# Function: getList
sub getList {
    my $self = shift;
    return $self->{list};
}

# Function: getHarvesting
sub getHarvesting {
    my $self = shift;
    return $self->{harvesting};
}

# Function: getImages
sub getImages {
    my $self = shift;
    return $self->{imageSource}->getImages();
}

# Function: hasImages
sub hasImages {
    my $self = shift;
    return (defined $self->{imageSource});
}

# Function: hasHarvesting
sub hasHarvesting {
    my $self = shift;
    return (defined $self->{harvesting});
}

# Function: getBottomID
sub getBottomID {
    my $self = shift;
    return $self->{bottomID};
}

# Function: getTopID
sub getTopID {
    my $self = shift;
    return $self->{topID};
}

# Function: getBottomOrder
sub getBottomOrder {
    my $self = shift;
    return $self->{bottomOrder};
}

# Function: getTopOrder
sub getTopOrder {
    my $self = shift;
    return $self->{topOrder};
}

=begin nd
Function: setBottomOrder

Parameters (list):
    bottomOrder - integer - Bottom level order to set
=cut
sub setBottomOrder {
    my $self = shift;
    my $bottomOrder = shift;
    $self->{bottomOrder} = $bottomOrder;
}

=begin nd
Function: setTopOrder

Parameters (list):
    topOrder - integer - Top level order to set
=cut
sub setTopOrder {
    my $self = shift;
    my $topOrder = shift;
    $self->{topOrder} = $topOrder;
}

=begin nd
Function: setTopID

Parameters (list):
    topID - string - Top level identifiant to set
=cut
sub setTopID {
    my $self = shift;
    my $topID = shift;
    $self->{topID} = $topID;
}

####################################################################################################
#                                Group: Export methods                                             #
####################################################################################################

=begin nd
Function: exportForDebug

Returns all informations about the data source. Useful for debug.

Example:
    (start code)
    (end code)
=cut
sub exportForDebug {
    my $self = shift ;
    
    my $export = "";
    
    $export .= sprintf "\n Object BE4::DataSource :\n";
    $export .= sprintf "\t Extent: %s\n",$self->{extent};
    $export .= sprintf "\t Levels ID (order):\n";
    $export .= sprintf "\t\t- bottom : %s (%s)\n",$self->{bottomID},$self->{bottomOrder};
    $export .= sprintf "\t\t- top : %s (%s)\n",$self->{topID},$self->{topOrder};

    $export .= sprintf "\t Data :\n";
    $export .= sprintf "\t\t- SRS : %s\n",$self->{srs};
    $export .= "\t\t- We have images\n" if (defined $self->{imageSource});
    $export .= "\t\t- We have a WMS service\n" if (defined $self->{harvesting});
    
    if (defined $self->{bbox}) {
        $export .= "\t\t Bbox :\n";
        $export .= sprintf "\t\t\t- xmin : %s\n",$self->{bbox}[0];
        $export .= sprintf "\t\t\t- ymin : %s\n",$self->{bbox}[1];
        $export .= sprintf "\t\t\t- xmax : %s\n",$self->{bbox}[2];
        $export .= sprintf "\t\t\t- ymax : %s\n",$self->{bbox}[3];
    }
    
    if (defined $self->{list}) {
        $export .= sprintf "\t\t List file : %s\n", $self->{list};
    }
    
    return $export;
}

1;
__END__
