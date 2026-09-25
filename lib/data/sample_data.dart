import 'package:latlong2/latlong.dart';

import '../models/place.dart';

/// Sample content so the map, cards and transport views have something real to
/// render before the backend exists.
///
/// Coordinates sit around central Bengaluru, matching the app's original
/// starting point, so the demo reads as one coherent neighbourhood rather than
/// a scatter.
class SampleData {
  SampleData._();

  /// The categories offered as shortcut pills under the search bar.
  static const List<PlaceCategory> categories = [
    PlaceCategory.restaurant,
    PlaceCategory.hotel,
    PlaceCategory.coffee,
    PlaceCategory.museum,
    PlaceCategory.attraction,
    PlaceCategory.shopping,
  ];

  static const List<Place> places = [
    Place(
      id: 'p1',
      name: 'Cubbon Park',
      category: PlaceCategory.attraction,
      latitude: 12.9763,
      longitude: 77.5929,
      rating: 4.6,
      reviewCount: 8420,
      openStatus: OpenStatus.open,
      closingTime: '20:00',
      address: 'Sampangi Rama Nagar',
      description:
          'One of the largest green spaces in the city, with walking paths, '
          'lakes and the Cubbon Park metro stop at the west gate.',
    ),
    Place(
      id: 'p2',
      name: 'Third Wave Coffee',
      category: PlaceCategory.coffee,
      latitude: 12.9695,
      longitude: 77.5963,
      rating: 4.4,
      reviewCount: 3180,
      openStatus: OpenStatus.open,
      closingTime: '23:00',
      address: 'Church Street',
      description: 'Specialty coffee on Church Street, a short walk from the metro.',
    ),
    Place(
      id: 'p3',
      name: 'Chinnaswamy Stadium',
      category: PlaceCategory.attraction,
      latitude: 12.9788,
      longitude: 77.5996,
      rating: 4.5,
      reviewCount: 12900,
      openStatus: OpenStatus.closed,
      address: 'MG Road',
      description: 'Test cricket ground in the heart of the city.',
    ),
    Place(
      id: 'p4',
      name: 'The Lalit Ashok',
      category: PlaceCategory.hotel,
      latitude: 12.9661,
      longitude: 77.6003,
      rating: 4.3,
      reviewCount: 2140,
      openStatus: OpenStatus.open,
      address: 'Kempapura',
      description: 'Long-standing luxury hotel with a large garden.',
    ),
    Place(
      id: 'p5',
      name: 'Indian Museum',
      category: PlaceCategory.museum,
      latitude: 12.9726,
      longitude: 77.5712,
      rating: 4.4,
      reviewCount: 5680,
      openStatus: OpenStatus.closingSoon,
      closingTime: '18:30',
      address: 'Jawaharlal Nehru Road',
      description: 'One of the oldest museums in India.',
    ),
    Place(
      id: 'p6',
      name: 'UB City',
      category: PlaceCategory.shopping,
      latitude: 12.9718,
      longitude: 77.5958,
      rating: 4.5,
      reviewCount: 9760,
      openStatus: OpenStatus.open,
      closingTime: '22:00',
      address: 'Vittal Mallya Road',
      description: 'Mixed-use complex with shops, offices and a food court.',
    ),
    Place(
      id: 'p7',
      name: 'Toit',
      category: PlaceCategory.restaurant,
      latitude: 12.9708,
      longitude: 77.6093,
      rating: 4.2,
      reviewCount: 6320,
      openStatus: OpenStatus.open,
      closingTime: '01:00',
      address: '100 Feet Road',
      description: 'Brewery and kitchen, busy from evening onwards.',
    ),
    Place(
      id: 'p8',
      name: 'Lalbagh Botanical Garden',
      category: PlaceCategory.park,
      latitude: 12.9507,
      longitude: 77.5848,
      rating: 4.7,
      reviewCount: 15200,
      openStatus: OpenStatus.open,
      closingTime: '18:00',
      address: 'Mavalli',
      description: 'A large botanical garden with a glasshouse.',
    ),
    Place(
      id: 'p9',
      name: 'Gangubai Kaum',
      category: PlaceCategory.hotel,
      latitude: 12.9654,
      longitude: 77.6182,
      rating: 4.1,
      reviewCount: 890,
      openStatus: OpenStatus.closed,
      address: 'VV Puram',
      description: 'Budget stay near the commercial district.',
    ),
    Place(
      id: 'p10',
      name: 'Koshy’s',
      category: PlaceCategory.restaurant,
      latitude: 12.9754,
      longitude: 77.6062,
      rating: 4.4,
      reviewCount: 4410,
      openStatus: OpenStatus.open,
      closingTime: '22:30',
      address: 'Sampangi Rama Nagar',
      description: 'Long-running bakery and restaurant chain.',
    ),
    Place(
      id: 'p11',
      name: 'National Gallery of Modern Art',
      category: PlaceCategory.museum,
      latitude: 12.9719,
      longitude: 77.6094,
      rating: 4.2,
      reviewCount: 1870,
      openStatus: OpenStatus.closed,
      address: 'M.G. Road',
      description: 'Modern and contemporary Indian art in a park setting.',
    ),
    Place(
      id: 'p12',
      name: 'Garuda Mall',
      category: PlaceCategory.shopping,
      latitude: 12.9667,
      longitude: 77.6071,
      rating: 4.0,
      reviewCount: 3320,
      openStatus: OpenStatus.open,
      closingTime: '22:00',
      address: 'Magrath Road',
      description: 'Neighbourhood shopping mall with a cinema.',
    ),
  ];

  /// Places in [category], or all of them when [category] is null.
  static List<Place> filter(PlaceCategory? category) => category == null
      ? places
      : places.where((p) => p.category == category).toList();

  /// Nearest-first ordering from [origin].
  static List<Place> sortedByDistance(List<Place> source, LatLng origin) {
    final list = [...source];
    list.sort((a, b) => a.distanceKmFrom(origin).compareTo(b.distanceKmFrom(origin)));
    return list;
  }
}
